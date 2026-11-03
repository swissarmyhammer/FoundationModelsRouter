import Foundation

/// The restore of the tool calls that a crash left open.
///
/// The session records one ``TranscriptEvent/Kind/toolCallStarted`` marker
/// when a tool call starts. The `.toolCalls` entry of the call follows at the
/// end of the submission. A restore reads the markers in this way:
///
/// - A marker that a later `.toolCalls` entry holds the call of is covered.
///   The entry is the record of the call, so the restore drops the marker.
/// - A marker that no later entry covers is an open call. The process ended
///   before the submission wrote its entries. The restore turns the open
///   calls that follow the same entry into one `.toolCalls` entry, and adds a
///   placeholder `.toolOutput` for each call, with the id of the call. The
///   transcript is then valid for the model: the model needs an output for
///   each call (``ToolCallOutputPairing``). The real result of a run arrives
///   later as run mail, not as this output.
///
/// The text of the placeholder follows the journal and the claims of the
/// host. The marker holds the completion token of the run of its call, and the
/// restore looks at the run in the journal:
///
/// - The run is claimed by the host (``runningOutput``): the host completes
///   the run, and the result arrives as run mail. A run is claimed when it is
///   orphaned, or when it wrote no event and an unended child holds its token
///   (``SessionTreeRestorationError/runNotClaimable(_:)``).
/// - The run is orphaned and not claimed (``lostOutput``): the restore posts a
///   lost terminal for it, and no result arrives.
/// - The run has a terminal event (``endedOutput``): the journal holds the
///   result.
/// - The call has no run in the journal (``unrecordedOutput``): an inline
///   tool may have finished before the crash, so the restore cannot tell if the
///   call ran. The text does not tell the model to call it again.
///
/// A call that has a real `.toolOutput` entry in the recording, and no
/// `.toolCalls` entry, gets its `.toolCalls` entry from the marker and no
/// placeholder: the model reads one output for the call.
enum OpenToolCalls {
    /// The text of the output that a restore gives to an open call whose run
    /// the host claimed. The run does not work in this process, but the host
    /// drives it again and completes it
    /// (``RoutedSession/completeClaimedRun(_:outcome:detail:)``). That event
    /// arrives as run mail.
    static let runningOutput =
        "The run of this tool call is still working. Its result will arrive in this "
        + "conversation as a message when it is ready."

    /// The text of the output that a restore gives to an open call whose run
    /// is orphaned and not claimed. The restore posts a lost terminal for the
    /// run, and the terminal arrives as run mail.
    static let lostOutput =
        "The run of this tool call was lost. The process stopped before the run ended. "
        + "A message in this conversation tells that the run was lost. No result will arrive."

    /// The text of the output that a restore gives to an open call whose run
    /// has a terminal event in the journal. The terminal is a run message in
    /// the conversation.
    static let endedOutput =
        "The run of this tool call has ended. Its result is in a run message of this conversation."

    /// The text of the output that a restore gives to an open call that has no
    /// run in the journal. The call may be an inline tool that finished before
    /// the crash, so the restore cannot tell if it ran.
    static let unrecordedOutput =
        "The result of this tool call was not recorded. The tool call may or may not have run. "
        + "Check the state before you repeat a call that is not safe to repeat."

    /// The prefix of the id of the `.toolCalls` entry that a restore makes.
    /// The id ends with the id of the first call, so it is the same at each
    /// restore of the same recording.
    private static let entryIDPrefix = "open-calls-"

    /// The suffix of the id of the text segment of a placeholder output.
    private static let placeholderSegmentSuffix = "-placeholder"

    /// `events`, with each covered marker dropped and each group of open
    /// markers turned into a `.toolCalls` entry with its placeholder outputs.
    ///
    /// A group is the open markers with no entry-kind event between them. It
    /// goes where its first marker was, ahead of the next entry-kind event.
    ///
    /// - Parameters:
    ///   - events: The events of one session, in `seq` order.
    ///   - claimedRuns: The runs that the host claimed at the restore. The
    ///     placeholder of a call of such a run says that the run is working.
    /// - Returns: The events with no marker.
    static func folding(_ events: [TranscriptEvent], claimedRuns: Set<RunKey> = []) -> [TranscriptEvent] {
        let lastCover = EventCover.lastIndex(in: events, coveredKeys: coveredCallIDs(by:))
        let statuses = OrphanRunScan(scanning: events).statuses
        let answered = Set(events.filter { $0.kind == .toolOutput }.compactMap { $0.entry?.entryId })
        var folded: [TranscriptEvent] = []
        var group: [TranscriptEvent] = []
        for (index, event) in events.enumerated() {
            if event.kind == .toolCallStarted {
                if let call = event.entry?.toolCalls?.first, (lastCover[call.id] ?? -1) < index {
                    group.append(event)
                }
                continue
            }
            if event.kind.isEntryKind {
                folded += openEvents(of: group, statuses: statuses, claimedRuns: claimedRuns, answered: answered)
                group = []
            }
            folded.append(event)
        }
        return folded + openEvents(of: group, statuses: statuses, claimedRuns: claimedRuns, answered: answered)
    }

    /// The ids of the calls that `event` covers: the calls of a `.toolCalls`
    /// event.
    ///
    /// - Parameter event: An event of one session.
    /// - Returns: The ids of the covered calls, or none for an event of
    ///   another kind.
    private static func coveredCallIDs(by event: TranscriptEvent) -> [String] {
        guard event.kind == .toolCalls else { return [] }
        return (event.entry?.toolCalls ?? []).map(\.id)
    }

    /// The `.toolCalls` event of one group of open markers, then one
    /// placeholder `.toolOutput` event for each call.
    ///
    /// - Parameters:
    ///   - group: The open markers, in order.
    ///   - statuses: The status of each run in the journal.
    ///   - claimedRuns: The runs that the host claimed.
    ///   - answered: The ids of the `.toolOutput` entries of the recording. A
    ///     call with a real output in it gets no placeholder.
    /// - Returns: The events, or none for an empty group.
    private static func openEvents(
        of group: [TranscriptEvent], statuses: [RunKey: RunStatus], claimedRuns: Set<RunKey>,
        answered: Set<String>
    ) -> [TranscriptEvent] {
        let calls = group.compactMap { $0.entry?.toolCalls?.first }
        guard let template = group.first, let first = calls.first else { return [] }
        let entry = TranscriptEntryPayload(entryId: entryIDPrefix + first.id, toolCalls: calls)
        let outputs = zip(group, calls).filter { !answered.contains($0.1.id) }.map { marker, call in
            rekinded(
                marker, as: .toolOutput,
                entry: placeholderPayload(for: call, statuses: statuses, claimedRuns: claimedRuns))
        }
        return [rekinded(template, as: .toolCalls, entry: entry)] + outputs
    }

    /// The payload of the placeholder `.toolOutput` that answers `call`.
    ///
    /// - Parameters:
    ///   - call: The open call.
    ///   - statuses: The status of each run in the journal.
    ///   - claimedRuns: The runs that the host claimed.
    /// - Returns: The payload, with the id of the call as its entry id.
    private static func placeholderPayload(
        for call: ToolCallPayload, statuses: [RunKey: RunStatus], claimedRuns: Set<RunKey>
    ) -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: call.id,
            segments: [.text(id: call.id + placeholderSegmentSuffix, content: text(for: call, statuses: statuses, claimedRuns: claimedRuns))],
            toolName: call.toolName)
    }

    /// The text of the placeholder output of `call`, by the claim and by the
    /// status of its run in the journal. A claimed run gets ``runningOutput``.
    /// A run that is not claimed gets ``lostOutput`` when it is orphaned,
    /// ``endedOutput`` when it has a terminal event, and ``unrecordedOutput``
    /// when the journal holds no event of it.
    private static func text(
        for call: ToolCallPayload, statuses: [RunKey: RunStatus], claimedRuns: Set<RunKey>
    ) -> String {
        guard let correlationID = call.correlationID else { return unrecordedOutput }
        let run = RunKey(tool: call.toolName, correlationID: correlationID)
        guard !claimedRuns.contains(run) else { return runningOutput }
        switch statuses[run] {
        case .orphaned: return lostOutput
        case .completed: return endedOutput
        case nil: return unrecordedOutput
        }
    }

    /// `event` as an event of another kind with another payload. The
    /// provenance, the `seq` and the time stay.
    ///
    /// - Parameters:
    ///   - event: The event to turn.
    ///   - kind: The kind of the new event.
    ///   - text: The body text of the new event, or `nil`.
    ///   - entry: The payload of the new event.
    /// - Returns: The new event.
    static func rekinded(
        _ event: TranscriptEvent, as kind: TranscriptEvent.Kind, text: String? = nil, entry: TranscriptEntryPayload
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: event.routerId, sessionId: event.sessionId, parentId: event.parentId, slot: event.slot,
            model: event.model, seq: event.seq, ts: event.ts, kind: kind, text: text, entry: entry)
    }
}
