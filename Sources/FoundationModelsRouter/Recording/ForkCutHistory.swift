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
/// A turn is one delivered mail whose body is a user message
/// (`MailBody.userMessage`) or a message of another session
/// (`MailBody.agentMessage`), from any route, in the order of delivery. This
/// is the count of the transcript of a client: one turn for each user message
/// and each delivered directory message. The count reads only the mail that
/// the source got: the ``MailRecord/mailDelivered(_:)`` records of the
/// `.prompt` events of the recording of the source, and the mail of the
/// running submission. A message that the source sends (a tool call of the
/// `sessions` or the `agents` tool) is not a turn of the source.
///
/// A `.prompt` entry that delivers no such mail starts no turn: a
/// continuation prompt of an answer, a prompt of the result of a background
/// run, an elicitation answer, a catalog change. It and its entries belong to
/// the turn before it. The checkpoint of a compaction is a `.prompt` event in
/// the recording too, and it is not a turn.
///
/// One `.prompt` entry can deliver more than one such mail (a batch). Each
/// mail is a turn of its own, and a cut inside the batch rounds to the edges
/// of the batch: ``SessionForkCut/beforeTurn(_:)`` of turn `n` cuts just
/// before the prompt that delivers mail `n`, and
/// ``SessionForkCut/afterTurn(_:)`` of turn `n` cuts at the end of the answer
/// to that prompt: just before the prompt of the next turn, or the end of
/// the history.
///
/// The turn index is 0-based, and it counts each turn that the source ever
/// recorded, also the turns that a compaction folded.
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
/// of it is out of range. ``SessionForkCut/lastCompletedTurn`` stops before
/// the first prompt of the running answer, also when that prompt starts no
/// turn (an answer to the result of a background run), and the end of an
/// earlier turn never comes after that prompt.
struct ForkCutHistory: Sendable, Equatable {
    /// One entry of the history, as the cut reads it.
    enum Entry: Sendable, Equatable {
        /// A `.prompt` entry that is not a compaction checkpoint. `turns` is
        /// the number of turns that it starts: its delivered mail that
        /// starts a turn (``Mail/startsATurn``).
        case prompt(turns: Int)

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
        /// backend and records its checkpoint before the next submission. A
        /// `.prompt` entry of a transcript holds no mail record, so it starts
        /// no turn here (``ForkCutHistory/runningEntries(_:delivering:)``).
        ///
        /// - Parameter entry: A transcript entry.
        init(_ entry: Transcript.Entry) {
            switch entry {
            case .prompt: self = .prompt(turns: 0)
            case .toolCalls: self = .toolCalls
            default: self = .other
            }
        }

        /// The `.prompt` entry that delivers `mail`.
        ///
        /// - Parameter mail: The mail that the prompt delivers.
        /// - Returns: A prompt with one turn for each mail that starts a turn.
        static func prompt(delivering mail: [Mail]) -> Self {
            .prompt(turns: mail.filter(\.startsATurn).count)
        }

        /// Whether the entry is a `.prompt` entry that is not a compaction
        /// checkpoint.
        var isPrompt: Bool {
            guard case .prompt = self else { return false }
            return true
        }

        /// The number of turns that the entry starts.
        var turns: Int {
            guard case .prompt(let turns) = self else { return 0 }
            return turns
        }
    }

    /// The entries of the history, in order.
    let entries: [Entry]

    /// The entries of the recorded history of a session: the folded history
    /// of `events` (``FoldedHistory``), the same entries that
    /// ``RoutedSessionActor/historyOrdinal`` counts. Each `.prompt` entry
    /// counts the turns of its ``MailRecord/mailDelivered(_:)`` records.
    ///
    /// - Parameter events: The effective events of the session, in order,
    ///   with the markers and the records of ``FoldedHistory/extraKinds``.
    /// - Returns: One entry for each entry of the folded history.
    static func recordedEntries(of events: [TranscriptEvent]) -> [Entry] {
        let folded = FoldedHistory.entries(of: events)
        let checkpoints = Set(TranscriptTree.compactionCheckpoints(in: folded).map(\.index))
        return folded.indices.map { index in
            switch folded[index].kind {
            case .prompt where checkpoints.contains(index): .compactionCheckpoint
            case .prompt: .prompt(delivering: deliveredMail(of: folded[index]))
            case .toolCalls: .toolCalls
            default: .other
            }
        }
    }

    /// The entries of the running submission that the session did not
    /// record yet. The last `.prompt` entry among them is the prompt of the
    /// submission, and it delivers `mail`, as the record of the submission
    /// does (``RoutedSessionActor/attachingDeliveredMailRecords(_:to:excluding:)``).
    ///
    /// - Parameters:
    ///   - entries: The transcript entries that the session did not record.
    ///   - mail: The mail that the running submission delivers.
    /// - Returns: One entry for each entry of `entries`.
    static func runningEntries(_ entries: some Collection<Transcript.Entry>, delivering mail: [Mail]) -> [Entry] {
        var running = entries.map(Entry.init)
        if let prompt = running.lastIndex(where: \.isPrompt) {
            running[prompt] = .prompt(delivering: mail)
        }
        return running
    }

    /// The mail that a recorded `.prompt` event delivered, in take order.
    ///
    /// - Parameter event: A `.prompt` event.
    /// - Returns: The mail of its ``MailRecord/mailDelivered(_:)`` records.
    private static func deliveredMail(of event: TranscriptEvent) -> [Mail] {
        event.mailRecords.compactMap { record in
            guard case .mailDelivered(let mail) = record else { return nil }
            return mail
        }
    }

    /// The position of the history where the answer that runs now started,
    /// or `nil` when the source runs no answer.
    let runningAnswerStart: Int?

    /// The position of the prompt of each turn, in order: one item for each
    /// turn, so a prompt that starts more than one turn (a batch) is there
    /// once for each of its turns.
    var turnStarts: [Int] {
        entries.indices.flatMap { Array(repeating: $0, count: entries[$0].turns) }
    }

    /// The position of the first `.prompt` entry of the running answer, or
    /// `nil` when no answer runs or it has no prompt yet.
    private var runningPromptStart: Int? {
        entries.indices.first { entries[$0].isPrompt && isRunning($0) }
    }

    /// The first position that a fork can cut at: the position after the
    /// newest compaction checkpoint, or `0` when the history holds none.
    var foldedEnd: Int {
        entries.lastIndex(of: .compactionCheckpoint).map { $0 + 1 } ?? 0
    }

    /// The position of `cut` in the history.
    ///
    /// - ``SessionForkCut/lastCompletedTurn``: the first prompt of the
    ///   running answer, or the end of the history.
    /// - ``SessionForkCut/callingToolCall``: the last `.toolCalls` entry of
    ///   the running answer, so the fork gets the history up to the call and
    ///   not the call.
    /// - ``SessionForkCut/historyPosition(_:)``: the position itself.
    /// - ``SessionForkCut/afterTurn(_:)``: the end of the answer to the
    ///   prompt of the turn: the prompt of the next turn, or the end of the
    ///   history.
    /// - ``SessionForkCut/beforeTurn(_:)``: the prompt that delivers the
    ///   mail of the turn.
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
            return runningPromptStart ?? entries.count
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

    /// The end of the answer to the prompt of the turn `index`: the prompt
    /// of the next turn after that prompt, or the end of the history. The
    /// end never comes after the start of the running answer.
    ///
    /// - Parameter index: The turn index.
    /// - Returns: The end, or `nil` when the turn does not exist, is folded,
    ///   or still runs.
    private func endOfCompleteTurn(_ index: Int) -> Int? {
        guard let start = unfoldedTurnStart(index), !isRunning(start) else { return nil }
        let historyEnd = runningPromptStart ?? entries.count
        return min(turnStarts.first { $0 > start } ?? historyEnd, historyEnd)
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

extension Mail {
    /// Whether the mail starts a turn of the session that gets it (D205,
    /// ``ForkCutHistory``): its body is a user message or a message of
    /// another session, from any route.
    var startsATurn: Bool {
        switch body {
        case .userMessage, .agentMessage:
            return true
        case .runEvent, .elicitationAnswer, .catalogChange:
            return false
        }
    }
}
