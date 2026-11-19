import FoundationModels
import FoundationModelsExtras
import Logging
import Metrics

/// What a fork of a session starts from (D205): its transcript, its position
/// in the history of its source, and its context counter.
struct ForkSeed {
    /// The transcript of the fork: the history of the source up to the cut,
    /// as the model reads it.
    let entries: [Transcript.Entry]

    /// The cut: the position in the recorded history of the source
    /// (``SessionRecord/forkedAtHistoryOrdinal``). It is also the first
    /// ``RoutedSessionActor/historyOrdinal`` of the fork.
    let historyOrdinal: Int

    /// The context counter of the fork, as a restore of the fork reads it
    /// (``TranscriptTree/restoredUsageState(in:)``).
    let usageState: ContextUsageState
}

/// ``RoutedSessionActor``'s live fork (D205): a new session with the history
/// of this session up to a cut.
extension RoutedSessionActor {
    /// Makes a live fork of this session at `cut`. The fork has the model,
    /// the slot, the instructions, the grammar, the settings and the tools of
    /// this session (each tool through `ForkableTool.forked()`), and the
    /// history of this session up to the cut. It records as a fork node in
    /// the recording folder of this session, with the cut in its record
    /// (``SessionRecord/forkedAtHistoryOrdinal``), and it copies no recorded
    /// history. The caller registers it (``RouterSessionDirectory/fork(_:)``).
    ///
    /// The cut is a position in the recorded history of this session
    /// (``ForkCutHistory``). The history comes from two places, read with no
    /// suspension point between them:
    ///
    /// - the recording of this session on disk, up to the position of the
    ///   last settled point (``settledTranscript``);
    /// - the entries of the running submission that the settled point holds
    ///   and that the session did not record yet, with the mail that the
    ///   submission delivers (``RunningSubmission/deliveredMail``).
    ///
    /// The fork reads nothing of the live backend transcript, with one
    /// exception: ``SessionForkCut/callingToolCall`` comes from a tool body of
    /// the open model call of this session, where the SDK waits in the tool
    /// call, so the call settles the transcript there first.
    ///
    /// The fork has no open tool call at its end: when the history at the cut
    /// ends in a round of calls with a call that has no output, the cut moves
    /// back to before that round.
    ///
    /// The source must record durably. The fork node and its cut live in the
    /// recording of the source, and the turn index counts the prompts of that
    /// recording.
    ///
    /// - Parameter cut: The cut of the fork.
    /// - Returns: The fork, not registered.
    /// - Throws: `SessionDirectoryError.forkUnsupported` when this session
    ///   records nothing durably or runs on a slot that has no session;
    ///   `SessionDirectoryError.forkCutOutOfRange` for a cut that
    ///   ``ForkCutHistory`` refuses, or a calling tool call outside a tool
    ///   body of the open model call of this session; the error of the read
    ///   of the recording (``TranscriptTreeError``,
    ///   ``TranscriptReconstructionError``).
    func makeFork(at cut: SessionForkCut) async throws -> RoutedSessionActor {
        guard persistsIndex else { throw SessionDirectoryError.forkUnsupported }
        let handle = try forkHandle()
        if cut == .callingToolCall {
            try settleAtCallingToolCall()
        }
        let seed = try forkSeed(at: cut)
        let fork = handle.makeFork(of: self, seed: seed)
        // Host settings, as the other settings of the fork are.
        await fork.setGenerationStallReportInterval(generationStallReportInterval)
        await fork.useTelemetry(logger: explicitLogger, metricsFactory: explicitMetricsFactory)
        return fork
    }

    /// The generation handle of the slot of this session: the handle that
    /// makes the fork.
    ///
    /// - Returns: The handle.
    /// - Throws: `SessionDirectoryError.forkUnsupported` for a slot with no
    ///   generation session.
    private func forkHandle() throws -> RoutedLLM {
        switch slot {
        case .standard: profile.standard
        case .flash: profile.flash
        case .embedding, .decision: throw SessionDirectoryError.forkUnsupported
        }
    }

    /// Takes the transcript as a settled point for a fork at the calling
    /// tool call: the caller is a tool body of the open model call of this
    /// session, so the SDK waits in the tool call and no call writes the
    /// transcript (``SessionCallMark``).
    ///
    /// - Throws: `SessionDirectoryError.forkCutOutOfRange` when the caller is
    ///   not such a tool body.
    private func settleAtCallingToolCall() throws {
        guard SessionCallMark.current?.isOpenCall(of: id) == true else {
            throw SessionDirectoryError.forkCutOutOfRange(.callingToolCall)
        }
        settleTranscript()
    }

    /// The seed of a fork at `cut`, from ``settledTranscript`` and the
    /// recording of this session. The call has no suspension point, so the
    /// settled point and the recording describe one moment.
    ///
    /// - Parameter cut: The cut of the fork.
    /// - Returns: The seed.
    /// - Throws: What ``makeFork(at:)`` throws for the cut and the read.
    private func forkSeed(at cut: SessionForkCut) throws -> ForkSeed {
        let settled = settledTranscript
        let events = try recordedForkEvents()
        let history = ForkCutHistory(
            entries: Array(ForkCutHistory.recordedEntries(of: events).prefix(settled.historyOrdinal))
                + ForkCutHistory.runningEntries(
                    settled.entries.dropFirst(settled.recordedEntryCount),
                    delivering: runningSubmission?.deliveredMail ?? []),
            runningAnswerStart: runningAnswerHistoryStart)
        var position = try history.position(of: cut)
        var entries = try Self.forkEntries(at: position, of: settled, events: events)
        while Self.endsInAnOpenRound(entries) {
            guard position > history.foldedEnd else { throw SessionDirectoryError.forkCutOutOfRange(cut) }
            position -= 1
            entries = try Self.forkEntries(at: position, of: settled, events: events)
        }
        let usageEvents = TranscriptTree.forkPrefix(of: events, entryCount: min(position, settled.historyOrdinal))
        return ForkSeed(
            entries: entries, historyOrdinal: position,
            usageState: TranscriptTree.restoredUsageState(in: usageEvents))
    }

    /// The position in the history where the answer that runs now started,
    /// or `nil` when no answer runs.
    private var runningAnswerHistoryStart: Int? {
        guard case .answer = pumpWork?.kind else { return nil }
        return answerStartHistoryOrdinal
    }

    /// The effective events of this session in its recording, with the
    /// kinds that the render of a fork reads (``TranscriptTree/renderKinds``)
    /// and the generation calls that its context counter reads. A fork of a
    /// fork reads the events of its parents up to its cut, as a restore does.
    ///
    /// - Returns: The events, in order.
    /// - Throws: ``TranscriptTreeError`` or the read error of a transcript.
    private func recordedForkEvents() throws -> [TranscriptEvent] {
        let root = TranscriptTree.recordingRoot(ofSessionIn: recordingDirectory)
        let tree = try TranscriptTree.loadChain(ofSessionIn: recordingDirectory, under: root)
        return try tree.effectiveEntryEvents(
            forSession: id, alongWith: TranscriptTree.renderKinds.union([.generationCall]))
    }

    /// The transcript of a fork at `position`.
    ///
    /// A position at or after the history position of the settled point
    /// takes the entries of the settled point: its recorded entries are the
    /// render of the history, and the entries after them are the running
    /// submission, which the session records later at the same positions.
    /// An earlier position renders the recording
    /// (``TranscriptTree/forkTranscript(of:entryCount:)``), as a restore of the
    /// fork does.
    ///
    /// - Parameters:
    ///   - position: The cut, in the recorded history.
    ///   - settled: The settled point of this session.
    ///   - events: The effective events of this session.
    /// - Returns: The entries of the fork.
    /// - Throws: ``TranscriptReconstructionError`` for an event that does not
    ///   rebuild.
    private static func forkEntries(
        at position: Int, of settled: SettledTranscript, events: [TranscriptEvent]
    ) throws -> [Transcript.Entry] {
        guard position < settled.historyOrdinal else {
            return Array(settled.entries.prefix(settled.recordedEntryCount + position - settled.historyOrdinal))
        }
        return Array(try TranscriptTree.forkTranscript(of: events, entryCount: position))
    }

    /// Whether the last round of tool calls of `entries` has a call with no
    /// output.
    ///
    /// - Parameter entries: The entries of a fork.
    /// - Returns: `true` when the fork would end with an open tool call.
    private static func endsInAnOpenRound(_ entries: [Transcript.Entry]) -> Bool {
        guard let round = entries.lastIndex(where: { ForkCutHistory.Entry($0) == .toolCalls }) else { return false }
        return !InFlightTranscript.openCalls(in: Array(entries[round...])).isEmpty
    }

    /// Takes the explicit logger and the explicit metrics factory of the
    /// source of this fork. They are host settings, so the records and the
    /// metrics of a fork go where those of its source go.
    ///
    /// - Parameters:
    ///   - logger: The explicit logger of the source, or `nil`.
    ///   - metricsFactory: The explicit metrics factory of the source, or
    ///     `nil`.
    private func useTelemetry(logger: Logger?, metricsFactory: (any MetricsFactory)?) {
        explicitLogger = logger
        explicitMetricsFactoryState.withLock { $0 = metricsFactory }
    }
}
