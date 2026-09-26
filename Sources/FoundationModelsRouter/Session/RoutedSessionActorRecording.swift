import Foundation
import FoundationModels
import os

/// The logger for transcript divergence warnings.
private let sessionRecordingLogger = makeModuleLogger(category: "Recording")

/// The recording path of ``RoutedSessionActor``: the per-turn usage delta,
/// the transcript diff that becomes recorded events, the re-queue of
/// unattached events, and the session meta event.
extension RoutedSessionActor {
    /// Computes the usage delta of the attempt, records the transcript diff,
    /// and ends the running submission: it sends
    /// ``SessionEvent/submissionEnded(_:)``, with the usage when the backend
    /// reports it.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The turn's start instant, used to stamp `ms`.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - responseTokenCeiling: The token ceiling the turn gave its backend,
    ///     or `nil` when it gave none.
    ///   - pendingEvents: The events this turn drained from the outbox.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    ///   - stopReason: The reason of a stop that the session made itself, or
    ///     `nil` to read the reason from the entries of the attempt.
    /// - Returns: Whether the diff included a `.response` entry, the turn's
    ///   usage delta (`nil` when unknown), whether `pendingEvents` were
    ///   attached to a persisted `.prompt` entry, and why the attempt stopped.
    private func finishTurn(
        grammar: Grammar?,
        since: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil,
        stopReason: FinishReason? = nil
    ) async -> (
        diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, pendingEventsAttached: Bool,
        finishReason: FinishReason
    ) {
        let usage = Self.usageDelta(before: usageBefore, after: backend.usageTokenCounts())
        // Read before the diff below, which moves the baseline past this
        // attempt's entries.
        let turnEntries = unrecordedTranscriptEntries()
        let finishReason =
            stopReason
            ?? FinishReason(
                turnEntries: turnEntries, outputTokens: usage?.output,
                lastCallOutputTokens: backend.lastGenerationCallOutputTokenCount(),
                responseTokenCeiling: responseTokenCeiling)
        // The last generation call of the attempt. Taken before the diff for
        // the same reason, and reported after it, so its journal event
        // follows the entries the call left.
        let lastGenerationCall = takeGenerationCall(leaving: GenerationCallEntryKind(leftBy: turnEntries))
        // The newest call of the attempt is the size of the render. Read it
        // before the ledger closes. An open ledger with no ended call gives
        // the delta of the attempt, which is then zero.
        let renderedContext = generationCallLedger?.newestCall ?? usage
        closeGenerationCallLedger()
        let (diffIncludedResponse, pendingEventsAttached) = await recordTranscriptDelta(
            grammar: grammar, since: since, usage: usage, pendingEvents: pendingEvents, onEvent: onEvent)
        // The submission ended, with success or failure, and its entries are
        // recorded: a settled point (`generation-queue.md`, section 5.8).
        settleTranscript()
        if let lastGenerationCall {
            await report(generationCall: lastGenerationCall)
        }
        // The counter is the size of the render that the session sends to
        // the model: the instructions, the latest compaction snapshot, and
        // the messages since that snapshot (task ^tpsc0nf). Each generation
        // call receives the whole render, so the fed and generated tokens of
        // the newest call are that size. The delta of the attempt is not: a
        // tool loop sends the whole render again at each call, and the delta
        // adds each of them. A compaction restarts the counter
        // (``runCompaction(prompt:budget:summarizers:)``).
        //
        // Only a turn whose diff included a `.response`-kind entry measured
        // the render. A turn rejected before it touched `backend` (for
        // example, a guided turn whose grammar validation throws pre-flight)
        // keeps the last known counter, and does not set it to a meaningless
        // zero. See ``usageState``.
        if diffIncludedResponse {
            usageState = renderedContext.map { .measured(input: $0.input, output: $0.output) } ?? .unknown
        }
        // Ends the submission that the session opened for this attempt. The
        // session sends ``SessionEvent/submissionEnded(_:)`` for every
        // submission it opened, also when the backend reports no usage: the
        // usage of the end is then `nil`. An attempt that the session refused
        // before it touched `backend` still measures a true (zero) delta
        // between two real snapshots, so its end carries that usage. The
        // usage reads `contextFill` after the `usageState` update above, so
        // the end of this attempt carries the fill it just measured, or the
        // prior value when this attempt did not touch `backend`
        // (compaction_plan.md §1.7, task g2hcm36).
        endSubmission(
            usage: usage.map {
                TokenUsage(
                    tokensIn: $0.input, tokensOut: $0.output, contextFill: contextFill, finishReason: finishReason)
            },
            finishReason: finishReason,
            measuredRender: diffIncludedResponse ? renderedContext : nil,
            onEvent: onEvent)
        return (diffIncludedResponse, usage, pendingEventsAttached, finishReason)
    }

    /// The entries of the backend transcript that ``persistedBaseline`` does
    /// not hold: the entries the attempt in flight appended.
    ///
    /// Read by entry id, so a transcript that diverged from the baseline still
    /// gives only its new entries.
    ///
    /// - Returns: The unrecorded entries, in transcript order.
    func unrecordedTranscriptEntries() -> [Transcript.Entry] {
        let recordedIds = Set(persistedBaseline.entryIds)
        return backend.transcriptEntries().filter { !recordedIds.contains($0.id) }
    }

    /// Finishes the turn and re-queues `pendingEvents` when the diff had no
    /// `.prompt` partial to attach them to.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force for this turn.
    ///   - started: The turn's start time.
    ///   - usageBefore: The token-usage snapshot taken before the turn ran.
    ///   - responseTokenCeiling: The token ceiling the turn gave its backend,
    ///     or `nil` when it gave none.
    ///   - pendingEvents: The events drained from ``outbox`` for this turn.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    ///   - stopReason: The reason of a stop that the session made itself, or
    ///     `nil` to read the reason from the entries of the attempt.
    /// - Returns: Whether the diff included a `.response` entry, the turn's
    ///   usage delta, and why the attempt stopped.
    func finishTurnAndRequeueIfUnattached(
        grammar: Grammar?,
        since started: Date,
        usageBefore: (input: Int, output: Int)?,
        responseTokenCeiling: Int?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil,
        stopReason: FinishReason? = nil
    ) async -> (diffIncludedResponse: Bool, usage: (input: Int, output: Int)?, finishReason: FinishReason) {
        let (diffIncludedResponse, usage, pendingEventsAttached, finishReason) = await finishTurn(
            grammar: grammar, since: started, usageBefore: usageBefore,
            responseTokenCeiling: responseTokenCeiling, pendingEvents: pendingEvents, onEvent: onEvent,
            stopReason: stopReason)
        // The pump already destructively took `pendingEvents` from `outbox`
        // before `body()` ran. When this submission's diff produced no
        // `.prompt`-kind partial to attach them to — every `.ebnf`-guided
        // turn, whose backend validates and throws before touching its live
        // session at all (see `MLXFoundationModelsSessionBackend.respond(to:
        // following:maxTokens:)`) — the
        // composed preamble was never actually delivered to the model and the
        // events were never persisted either. Re-queue them so a future turn
        // gets another chance, instead of the drain silently destroying state
        // a failed turn never got to deliver.
        if !pendingEventsAttached {
            await requeueUnattachedPendingEvents(events: pendingEvents)
        }
        return (diffIncludedResponse, usage, finishReason)
    }

    /// Re-posts `events` onto ``outbox`` through `SessionOutbox.requeue(event:)`.
    /// The events are not journaled a second time, and they are held
    /// (``SessionOutbox/PendingEvent/isHeld``), so a submission that could
    /// not take them is not started again at once.
    ///
    /// - Parameter events: The events to re-queue, in outbox order.
    func requeueUnattachedPendingEvents(events: [OperationEvent]) async {
        for event in events {
            await outbox.requeue(event: event)
        }
    }

    /// The token usage delta between two ``LanguageModelSessionBackend/usageTokenCounts()``
    /// snapshots.
    ///
    /// - Parameters:
    ///   - before: The snapshot taken before the turn ran.
    ///   - after: The snapshot taken after the turn returned or threw.
    /// - Returns: The turn's `(input, output)` token counts, or `nil` when
    ///   either snapshot is `nil`.
    static func usageDelta(
        before: (input: Int, output: Int)?,
        after: (input: Int, output: Int)?
    ) -> (input: Int, output: Int)? {
        guard let before, let after else { return nil }
        return (after.input - before.input, after.output - before.output)
    }

    /// Diffs the backend transcript against ``persistedBaseline`` and records
    /// each entry the SDK appended since the last diff. A transcript only
    /// appends: no branch here drops an entry.
    ///
    /// A transcript that still extends the recorded prefix is diffed by
    /// position from ``persistedEntryCount``. A transcript that diverged from
    /// the baseline (``TranscriptDiffer/divergence(from:in:)``: an entry id
    /// moved, the boundary entry was rewritten in place, or the transcript
    /// shrank) is diffed by entry id instead, so every entry the record has
    /// never seen is appended, in transcript order, and then one
    /// ``TranscriptEvent/Kind/divergence`` marker is appended beside them.
    /// An entry rewritten under a recorded id is not appended a second time;
    /// the marker names it. After any recorded diff the whole current
    /// transcript becomes the baseline and ``persistedEntryCount`` its
    /// count: every entry of it is then in the record, either from before or
    /// from this diff, so the reset loses nothing. `ms` and `usage` are
    /// stamped on the last `.response` partial only. Each recorded partial
    /// emits its ``SessionEvent``s on a diverged turn exactly as on a plain
    /// one.
    ///
    /// - Parameters:
    ///   - grammar: The guided-generation grammar in force.
    ///   - since: The turn's start instant used to stamp `ms`, or `nil`.
    ///   - usage: The turn's `(input, output)` token delta, or `nil`.
    ///   - pendingEvents: The events this turn drained from the outbox.
    ///   - onEvent: A sink for derived ``SessionEvent``s, or `nil`.
    /// - Returns: Whether the diff included a `.response` entry, and whether
    ///   `pendingEvents` were attached to a `.prompt` partial (`true` when
    ///   `pendingEvents` is empty).
    private func recordTranscriptDelta(
        grammar: Grammar?,
        since: Date?,
        usage: (input: Int, output: Int)?,
        pendingEvents: [OperationEvent],
        onEvent: ((SessionEvent) -> Void)? = nil
    ) async -> (diffIncludedResponse: Bool, pendingEventsAttached: Bool) {
        let current = Transcript(entries: backend.transcriptEntries())
        let divergence = TranscriptDiffer.divergence(from: persistedBaseline, in: current)
        let diffPartials = TranscriptDiffer.partials(
            baseline: persistedBaseline,
            current: current,
            divergence: divergence,
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model
        )
        guard divergence != nil || !diffPartials.isEmpty else { return (false, pendingEvents.isEmpty) }

        let lastResponseIndex = diffPartials.lastIndex { $0.kind == .response }
        let (recordedPartials, pendingEventsAttached) = Self.attachingPendingEventSegments(
            events: pendingEvents, to: diffPartials)

        // Tool-call ids this diff has announced (`.toolCalls`) versus resolved
        // (`.toolOutput`), in request order — consulted once the loop finishes
        // to report any call whose output never arrived within this same
        // diff as ``SessionEvent/toolStatus(id:status:summary:output:)`` `.failed`.
        // Stay empty (and cost nothing further) when `onEvent` is `nil`, which
        // no turn's own sink is.
        var dispatchedToolCallIds: [String] = []
        var completedToolCallIds: Set<String> = []

        for (index, recordedPartial) in recordedPartials.enumerated() {
            let isTurnClose = index == lastResponseIndex
            let stampSince = (since != nil && isTurnClose) ? since : nil
            let stampUsage = (usage != nil && isTurnClose) ? usage : nil
            await append(
                partial: makePartialEvent(
                    kind: recordedPartial.kind,
                    grammar: grammar,
                    text: recordedPartial.text,
                    since: stampSince,
                    entry: recordedPartial.entry,
                    tokensIn: stampUsage?.input,
                    tokensOut: stampUsage?.output
                )
            )
            Self.emitSessionEvents(
                for: recordedPartial,
                dispatchedToolCallIds: &dispatchedToolCallIds,
                completedToolCallIds: &completedToolCallIds,
                onEvent: onEvent
            )
        }
        for id in dispatchedToolCallIds where !completedToolCallIds.contains(id) {
            onEvent?(.toolStatus(id: id, status: .failed, summary: nil, output: nil))
        }
        if let divergence {
            await appendDivergenceMarker(divergence, grammar: grammar)
        }
        persistedEntryCount = current.count
        persistedBaseline = TranscriptDiffer.Baseline(transcript: current)
        return (lastResponseIndex != nil, pendingEventsAttached)
    }

    /// Logs `divergence` and appends its ``TranscriptEvent/Kind/divergence``
    /// marker, after the entries the diverged turn recorded.
    ///
    /// - Parameters:
    ///   - divergence: The non-append change the turn's diff found.
    ///   - grammar: The guided-generation grammar in force.
    private func appendDivergenceMarker(_ divergence: TranscriptDiffer.Divergence, grammar: Grammar?) async {
        sessionRecordingLogger.warning(
            """
            \(divergence.description, privacy: .public) for session \
            \(self.id.description, privacy: .public); the turn's unseen entries are recorded and a \
            divergence marker follows them
            """
        )
        await append(partial: makePartialEvent(kind: .divergence, grammar: grammar, text: divergence.description))
    }

    /// Appends one ``OperationEventSegment`` per event onto the last
    /// `.prompt` partial in `diffPartials`.
    ///
    /// - Parameters:
    ///   - events: The events to attach, in outbox order.
    ///   - diffPartials: The turn's diff, in transcript order.
    /// - Returns: The partials to record, and whether the segments were
    ///   attached. `attached` is `true` when `events` is empty and `false`
    ///   when no `.prompt` partial with an entry exists.
    static func attachingPendingEventSegments(
        events: [OperationEvent],
        to diffPartials: [TranscriptEvent.Partial]
    ) -> (partials: [TranscriptEvent.Partial], attached: Bool) {
        guard !events.isEmpty else { return (diffPartials, true) }
        guard let promptIndex = diffPartials.lastIndex(where: { $0.kind == .prompt }),
            let entry = diffPartials[promptIndex].entry
        else {
            return (diffPartials, false)
        }
        let segments = events.map { event in
            TranscriptEntryMapper.segmentPayload(OperationEventSegment(content: event).transcriptSegment)
        }
        var partials = diffPartials
        partials[promptIndex] = partials[promptIndex].mapBody { text, _ in
            (text, entry.appendingSegments(segments))
        }
        return (partials, true)
    }

    /// Emits the ``SessionEvent``s that one recorded diff partial implies.
    /// Recording-level gating does not apply to these live events.
    ///
    /// A `.toolCalls` partial emits a `toolCall` and a running `toolStatus`
    /// per call, then an `entryRecorded`. A `.toolOutput` partial emits a
    /// completed `toolStatus` with an id from
    /// ``ToolCallOutputPairing/completedToolCallId(forOutputEntryId:dispatched:completed:)``.
    /// A `.reasoning` partial emits a `reasoningDelta` and an `entryRecorded`.
    /// A `.response` partial emits one `entryRecorded`. Other kinds emit nothing.
    ///
    /// - Parameters:
    ///   - partial: The diff partial just recorded.
    ///   - dispatchedToolCallIds: Tool-call ids announced in this diff; appended to.
    ///   - completedToolCallIds: Tool-call ids resolved in this diff; inserted into.
    ///   - onEvent: The sink for derived events, or `nil` to do nothing.
    private static func emitSessionEvents(
        for partial: TranscriptEvent.Partial,
        dispatchedToolCallIds: inout [String],
        completedToolCallIds: inout Set<String>,
        onEvent: ((SessionEvent) -> Void)?
    ) {
        guard let onEvent, let entry = partial.entry else { return }
        switch partial.kind {
        case .toolCalls:
            for call in entry.toolCalls ?? [] {
                onEvent(.toolCall(id: call.id, name: call.toolName, argumentsJSON: call.argumentsJSON))
                onEvent(.toolStatus(id: call.id, status: .running, summary: nil, output: nil))
                dispatchedToolCallIds.append(call.id)
            }
            onEvent(.entryRecorded(id: entry.entryId, kind: .toolCalls))
        case .toolOutput:
            let callId = ToolCallOutputPairing.completedToolCallId(
                forOutputEntryId: entry.entryId,
                dispatched: dispatchedToolCallIds,
                completed: completedToolCallIds
            )
            completedToolCallIds.insert(callId)
            onEvent(.toolStatus(id: callId, status: .completed, summary: partial.text, output: entry.segments))
        case .reasoning:
            onEvent(.reasoningDelta(partial.text ?? ""))
            onEvent(.entryRecorded(id: entry.entryId, kind: .reasoning))
        case .response:
            onEvent(.entryRecorded(id: entry.entryId, kind: .response))
        case .session, .instructions, .prompt, .embedding, .divergence, .generationCall, .repeatedPartRemoval,
            .toolCall, .unknown:
            break
        }
    }

    /// Records the `session` meta event once, before the first recorded entry.
    /// The event carries this session's ``agentSpawn``, so a live sink sees
    /// the spawn fact without a read of `session.json`.
    func recordSessionMetaIfNeeded() async {
        guard !didRecordSessionMeta else { return }
        didRecordSessionMeta = true
        await append(partial: makePartialEvent(kind: .session, grammar: grammar, agentSpawn: agentSpawn))
    }

    /// Appends a partial event through the recorder into this session's
    /// transcript directory. Advances ``historyOrdinal`` for each entry-kind
    /// partial.
    ///
    /// - Parameter partial: The event to record, without `seq` and `ts`.
    func append(partial: TranscriptEvent.Partial) async {
        if partial.kind.isEntryKind {
            historyOrdinal += 1
        }
        await recorder.append(partial, to: recordingDirectory)
    }

    /// The number of milliseconds in one second, the scale of ``TranscriptEvent/ms``.
    private static let millisecondsPerSecond: Double = 1_000

    /// Builds an event of the given kind stamped with this session's provenance.
    ///
    /// - Parameters:
    ///   - kind: The event kind.
    ///   - grammar: The guided-generation grammar in force, or `nil`.
    ///   - text: The event's flattened body text, or `nil`.
    ///   - since: The turn's start instant used to stamp `ms`, or `nil`.
    ///   - entry: The structural payload that mirrors `Transcript.Entry`, or `nil`.
    ///   - tokensIn: The turn's input token delta, or `nil`.
    ///   - tokensOut: The turn's output token delta, or `nil`.
    ///   - agentSpawn: The spawn context to stamp, or `nil`. Only the
    ///     `.session` kind carries one.
    /// - Returns: The partial event for the recorder to stamp and append.
    func makePartialEvent(
        kind: TranscriptEvent.Kind,
        grammar: Grammar? = nil,
        text: String? = nil,
        since: Date? = nil,
        entry: TranscriptEntryPayload? = nil,
        tokensIn: Int? = nil,
        tokensOut: Int? = nil,
        agentSpawn: SessionSidecar.AgentSpawn? = nil
    ) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: routerId,
            sessionId: id,
            parentId: parentId,
            slot: slot,
            model: model,
            kind: kind,
            grammar: grammar?.source,
            text: text,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            ms: since.map { Int(Date().timeIntervalSince($0) * Self.millisecondsPerSecond) },
            entry: entry,
            agentSpawn: agentSpawn
        )
    }
}
