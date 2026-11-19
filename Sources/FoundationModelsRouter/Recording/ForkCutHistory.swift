import FoundationModels
import FoundationModelsExtras

/// The history of a fork source as the cut of a fork reads it (D205): the
/// rule that maps a `SessionForkCut` to a position in the recorded history of
/// the source.
///
/// A position counts the entries of the append-only history of the source,
/// as ``RoutedSessionActor/historyOrdinal`` and
/// ``SessionRecord/forkedAtHistoryOrdinal`` count them. A fork at position
/// `n` gets the first `n` entries of that history.
///
/// ## Turns
///
/// A turn is one `.prompt` entry and all the entries after it, up to the
/// next `.prompt` entry. A `.prompt` entry is a user message, or a delivered
/// message that starts a submission. The checkpoint of a compaction is a
/// `.prompt` event in the recording too, but it is not a turn. The turn index
/// is 0-based, and it counts every `.prompt` entry that the source ever
/// recorded, also the turns that a compaction folded. This is the count of the
/// transcript of a client.
///
/// ## The folded range
///
/// The newest compaction checkpoint folds each turn whose prompt comes before
/// it. A fork cannot cut inside the folded range: the summary of the
/// compaction also tells of the turns after such a cut, so a fork from it
/// would know its own future. Thus each cut must keep the newest checkpoint
/// (``foldedEnd``), and a turn cut of a folded turn is out of range. A cut
/// after the checkpoint gives the summary and the turns after it, up to the
/// cut.
///
/// ## The running turn
///
/// A turn whose prompt comes at or after ``runningAnswerStart`` belongs to
/// the answer that runs now. It is not complete: ``SessionForkCut/afterTurn(_:)``
/// of it is out of range, and ``SessionForkCut/lastCompletedTurn`` stops
/// before it.
struct ForkCutHistory: Sendable, Equatable {
    /// One entry of the history, as the cut reads it.
    enum Entry: Sendable, Equatable {
        /// A `.prompt` entry: the start of a turn.
        case prompt

        /// The checkpoint of a compaction (``CompactionSegment``).
        case compactionCheckpoint

        /// A `.toolCalls` entry: one round of tool calls.
        case toolCalls

        /// Each other entry: the instructions, a response, a tool output, a
        /// reasoning entry.
        case other

        /// The entry that a transcript entry is. A transcript entry is never
        /// a compaction checkpoint here: only the entries of the running
        /// submission come from a transcript, and a compaction reseeds the
        /// backend and records its checkpoint before the next submission.
        ///
        /// - Parameter entry: A transcript entry.
        init(_ entry: Transcript.Entry) {
            switch entry {
            case .prompt: self = .prompt
            case .toolCalls: self = .toolCalls
            default: self = .other
            }
        }
    }

    /// The entries of the history, in order.
    let entries: [Entry]

    /// The entries of the recorded history of a session: the folded history
    /// of `events` (``FoldedHistory``), the same entries that
    /// ``RoutedSessionActor/historyOrdinal`` counts.
    ///
    /// - Parameter events: The effective events of the session, in order,
    ///   with the markers and the records of ``FoldedHistory/extraKinds``.
    /// - Returns: One entry for each entry of the folded history.
    static func recordedEntries(of events: [TranscriptEvent]) -> [Entry] {
        let folded = FoldedHistory.entries(of: events)
        let checkpoints = Set(TranscriptTree.compactionCheckpoints(in: folded).map(\.index))
        return folded.indices.map { index in
            switch folded[index].kind {
            case .prompt: checkpoints.contains(index) ? .compactionCheckpoint : .prompt
            case .toolCalls: .toolCalls
            default: .other
            }
        }
    }

    /// The position of the history where the answer that runs now started,
    /// or `nil` when the source runs no answer.
    let runningAnswerStart: Int?

    /// The position of the prompt of each turn, in order.
    var turnStarts: [Int] {
        entries.indices.filter { entries[$0] == .prompt }
    }

    /// The first position that a fork can cut at: the position after the
    /// newest compaction checkpoint, or `0` when the history holds none.
    var foldedEnd: Int {
        entries.lastIndex(of: .compactionCheckpoint).map { $0 + 1 } ?? 0
    }

    /// The position of `cut` in the history.
    ///
    /// - ``SessionForkCut/lastCompletedTurn``: the prompt of the first
    ///   running turn, or the end of the history.
    /// - ``SessionForkCut/callingToolCall``: the last `.toolCalls` entry of
    ///   the running answer, so the fork gets the history up to the call and
    ///   not the call.
    /// - ``SessionForkCut/historyPosition(_:)``: the position itself.
    /// - ``SessionForkCut/afterTurn(_:)``: the prompt of the next turn, or
    ///   the end of the history.
    /// - ``SessionForkCut/beforeTurn(_:)``: the prompt of the turn.
    ///
    /// - Parameter cut: The cut of the fork.
    /// - Returns: The position, from ``foldedEnd`` to the end of the history.
    /// - Throws: `SessionDirectoryError.forkCutOutOfRange` for a cut that the
    ///   rules of this type do not allow.
    func position(of cut: SessionForkCut) throws -> Int {
        guard let position = candidatePosition(of: cut), (foldedEnd...entries.count).contains(position) else {
            throw SessionDirectoryError.forkCutOutOfRange(cut)
        }
        return position
    }

    /// The position of `cut` before the check of the range.
    ///
    /// - Parameter cut: The cut of the fork.
    /// - Returns: The position, or `nil` when the cut names nothing that the
    ///   history holds.
    private func candidatePosition(of cut: SessionForkCut) -> Int? {
        switch cut {
        case .lastCompletedTurn:
            return turnStarts.first(where: isRunning) ?? entries.count
        case .callingToolCall:
            return callingRoundPosition
        case .historyPosition(let position):
            return position
        case .afterTurn(let index):
            return endOfCompleteTurn(index)
        case .beforeTurn(let index):
            return unfoldedTurnStart(index)
        }
    }

    /// The position of the last `.toolCalls` entry of the running answer, or
    /// `nil` when no answer runs or it has no round.
    private var callingRoundPosition: Int? {
        guard let runningAnswerStart, let round = entries.lastIndex(of: .toolCalls),
            round >= runningAnswerStart
        else { return nil }
        return round
    }

    /// The end of the turn `index`: the prompt of the next turn, or the end
    /// of the history.
    ///
    /// - Parameter index: The turn index.
    /// - Returns: The end, or `nil` when the turn does not exist, is folded,
    ///   or still runs.
    private func endOfCompleteTurn(_ index: Int) -> Int? {
        guard let start = unfoldedTurnStart(index), !isRunning(start) else { return nil }
        let starts = turnStarts
        return starts.indices.contains(index + 1) ? starts[index + 1] : entries.count
    }

    /// The prompt of the turn `index`.
    ///
    /// - Parameter index: The turn index.
    /// - Returns: The position of the prompt, or `nil` when the turn does not
    ///   exist or the newest compaction folded it.
    private func unfoldedTurnStart(_ index: Int) -> Int? {
        let starts = turnStarts
        guard starts.indices.contains(index), starts[index] >= foldedEnd else { return nil }
        return starts[index]
    }

    /// Whether the turn whose prompt is at `start` belongs to the running
    /// answer.
    ///
    /// - Parameter start: The position of the prompt of a turn.
    /// - Returns: `true` for a turn of the answer that runs now.
    private func isRunning(_ start: Int) -> Bool {
        runningAnswerStart.map { start >= $0 } ?? false
    }
}
