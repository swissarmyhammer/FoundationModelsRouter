import Foundation

/// The history of a session as its restore shows it: the entry-kind events,
/// with the open write-ahead markers folded into entries.
///
/// A restore turns each open ``TranscriptEvent/Kind/promptStarted`` marker
/// into a `.prompt` entry (``OpenPrompts``), and each group of open
/// ``TranscriptEvent/Kind/toolCallStarted`` markers into a `.toolCalls` entry
/// with its placeholder outputs (``OpenToolCalls``). The backend of the
/// restored session holds those entries, and the recording does not. A cut in
/// the history of such a session counts them. This type counts them in one
/// place, for the position of a restored session (``TranscriptTree``) and for
/// the cut of a fork (``TranscriptTree/forkPrefix(of:entryCount:)``).
enum FoldedHistory {
    /// The kinds that the fold reads, besides the entry kinds: the markers,
    /// and the records that end the mail of a marker.
    static let extraKinds: Set<TranscriptEvent.Kind> = [.promptStarted, .toolCallStarted, .mail]

    /// The place of each entry of the folded history in `events`.
    ///
    /// An entry that an event of `events` is has the index of that event. An
    /// entry that the fold makes has the index of the marker that it comes
    /// from.
    ///
    /// - Parameter events: The events of one session, in order, with the
    ///   markers and the records of ``extraKinds``.
    /// - Returns: One index for each entry of the folded history, in order.
    static func entryOrigins(of events: [TranscriptEvent]) -> [Int] {
        let numbered = events.enumerated().map { index, event in event.numbered(index) }
        return OpenToolCalls.folding(OpenPrompts.folding(numbered)).filter(\.kind.isEntryKind).map(\.seq)
    }
}

extension TranscriptEvent {
    /// This event with `seq` as the sequence number: the event as the fold
    /// finds its place by the position among the events.
    ///
    /// - Parameter seq: The new sequence number.
    /// - Returns: The event.
    fileprivate func numbered(_ seq: Int) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerId,
            sessionId: sessionId,
            parentId: parentId,
            slot: slot,
            model: model,
            seq: seq,
            ts: ts,
            kind: kind,
            grammar: grammar,
            text: text,
            tokensIn: tokensIn,
            tokensCached: tokensCached,
            tokensOut: tokensOut,
            ms: ms,
            timeToFirstTokenMs: timeToFirstTokenMs,
            decodeMs: decodeMs,
            callMs: callMs,
            firstTokenSeen: firstTokenSeen,
            outputBuffered: outputBuffered,
            entry: entry,
            agentSpawn: agentSpawn)
    }
}
