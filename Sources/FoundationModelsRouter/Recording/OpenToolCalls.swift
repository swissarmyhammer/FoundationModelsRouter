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
enum OpenToolCalls {
    /// The text of the output that a restore gives to an open call.
    ///
    /// A synchronous tool run ends with the process, and its result is lost.
    /// A background run can still end, and its terminal event arrives as run
    /// mail. The text states both: the result is not here, and it can still
    /// arrive.
    static let placeholderOutput =
        "The result of this tool call was not recorded. If its run still works, "
        + "its result will arrive in this conversation as a message when it is ready."

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
    /// - Parameter events: The events of one session, in `seq` order.
    /// - Returns: The events with no marker.
    static func folding(_ events: [TranscriptEvent]) -> [TranscriptEvent] {
        let lastCover = lastCoveringIndex(in: events)
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
                folded += openEvents(of: group)
                group = []
            }
            folded.append(event)
        }
        return folded + openEvents(of: group)
    }

    /// The index of the last `.toolCalls` event that holds each call id.
    ///
    /// - Parameter events: The events of one session.
    /// - Returns: The index of the newest covering event, by call id.
    private static func lastCoveringIndex(in events: [TranscriptEvent]) -> [String: Int] {
        var lastCover: [String: Int] = [:]
        for (index, event) in events.enumerated() where event.kind == .toolCalls {
            for call in event.entry?.toolCalls ?? [] {
                lastCover[call.id] = index
            }
        }
        return lastCover
    }

    /// The `.toolCalls` event of one group of open markers, then one
    /// placeholder `.toolOutput` event for each call.
    ///
    /// - Parameter group: The open markers, in order.
    /// - Returns: The events, or none for an empty group.
    private static func openEvents(of group: [TranscriptEvent]) -> [TranscriptEvent] {
        let calls = group.compactMap { $0.entry?.toolCalls?.first }
        guard let template = group.first, let first = calls.first else { return [] }
        let entry = TranscriptEntryPayload(entryId: entryIDPrefix + first.id, toolCalls: calls)
        let outputs = zip(group, calls).map { marker, call in
            rekinded(marker, as: .toolOutput, entry: placeholderPayload(for: call))
        }
        return [rekinded(template, as: .toolCalls, entry: entry)] + outputs
    }

    /// The payload of the placeholder `.toolOutput` that answers `call`.
    ///
    /// - Parameter call: The open call.
    /// - Returns: The payload, with the id of the call as its entry id.
    private static func placeholderPayload(for call: ToolCallPayload) -> TranscriptEntryPayload {
        TranscriptEntryPayload(
            entryId: call.id,
            segments: [.text(id: call.id + placeholderSegmentSuffix, content: placeholderOutput)],
            toolName: call.toolName)
    }

    /// `event` as an event of another kind with another payload. The
    /// provenance, the `seq` and the time stay.
    private static func rekinded(
        _ event: TranscriptEvent, as kind: TranscriptEvent.Kind, entry: TranscriptEntryPayload
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: event.routerId, sessionId: event.sessionId, parentId: event.parentId, slot: event.slot,
            model: event.model, seq: event.seq, ts: event.ts, kind: kind, entry: entry)
    }
}
