import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The rule that maps the cut of a fork to a position in the history of its
/// source (D205, ``ForkCutHistory``): the turns, the running turn, the
/// folded range of a compaction and the tool call that asks for the fork.
@Suite struct ForkCutHistoryTests {
    /// The history of two complete turns: the instructions, then a prompt
    /// and a response for each turn.
    private static let twoTurns: [ForkCutHistory.Entry] = [.other, .prompt, .other, .prompt, .other]

    /// The position of the prompt of the second turn of ``twoTurns``.
    private static let secondTurnStart = 3

    /// The history of two turns, a compaction that folds both, and one turn
    /// after the compaction.
    private static let compactedHistory: [ForkCutHistory.Entry] = [
        .other, .prompt, .other, .prompt, .other, .compactionCheckpoint, .prompt, .other,
    ]

    /// The position of the compaction checkpoint of ``compactedHistory``.
    private static let checkpointPosition = 5

    /// The position of the prompt of the turn after the compaction of
    /// ``compactedHistory``: turn 2, because the folded turns count.
    private static let turnAfterCompactionStart = 6

    /// The index of the turn after the compaction of ``compactedHistory``.
    private static let turnAfterCompaction = 2

    /// The history of a turn that runs a tool call: the prompt, a round
    /// with its output, then the round of the call that asks for the fork.
    private static let runningToolTurn: [ForkCutHistory.Entry] = [
        .other, .prompt, .other, .prompt, .toolCalls, .other, .toolCalls,
    ]

    /// The position where the running answer of ``runningToolTurn`` started.
    private static let runningToolTurnStart = 3

    /// The position of the last round of ``runningToolTurn``.
    private static let callingRoundPosition = 6

    /// Gives the error of `body`, or `nil` when it throws none.
    ///
    /// - Parameter body: The work that can throw.
    /// - Returns: The error as a directory error, or `nil`.
    private static func directoryError(_ body: () throws -> Int) -> SessionDirectoryError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? SessionDirectoryError
        }
    }

    // MARK: - The last completed turn

    @Test func theLastCompletedTurnOfAnIdleSourceIsTheEndOfTheHistory() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .lastCompletedTurn) == Self.twoTurns.count)
    }

    @Test func theLastCompletedTurnOfAWorkingSourceEndsBeforeTheRunningTurn() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: Self.secondTurnStart)

        #expect(try history.position(of: .lastCompletedTurn) == Self.secondTurnStart)
    }

    // MARK: - Turn cuts

    @Test func afterTheFirstTurnIsThePromptOfTheSecondTurn() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .afterTurn(0)) == Self.secondTurnStart)
    }

    @Test func afterTheLastCompleteTurnIsTheEndOfTheHistory() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .afterTurn(1)) == Self.twoTurns.count)
    }

    @Test func afterARunningTurnIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: Self.secondTurnStart)

        #expect(Self.directoryError { try history.position(of: .afterTurn(1)) } == .forkCutOutOfRange(.afterTurn(1)))
    }

    @Test func beforeTheSecondTurnIsItsPrompt() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(1)) == Self.secondTurnStart)
    }

    @Test func beforeARunningTurnIsItsPrompt() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: Self.secondTurnStart)

        #expect(try history.position(of: .beforeTurn(1)) == Self.secondTurnStart)
    }

    @Test func aTurnIndexThatDoesNotExistIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(Self.directoryError { try history.position(of: .beforeTurn(2)) } == .forkCutOutOfRange(.beforeTurn(2)))
    }

    @Test func aNegativeTurnIndexIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(Self.directoryError { try history.position(of: .afterTurn(-1)) } == .forkCutOutOfRange(.afterTurn(-1)))
    }

    // MARK: - Compaction

    @Test func aTurnAfterTheCompactionKeepsItsIndexAmongTheFoldedTurns() throws {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(Self.turnAfterCompaction)) == Self.turnAfterCompactionStart)
    }

    @Test func afterATurnThatTheCompactionFoldedIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        #expect(Self.directoryError { try history.position(of: .afterTurn(1)) } == .forkCutOutOfRange(.afterTurn(1)))
    }

    @Test func beforeATurnThatTheCompactionFoldedIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        #expect(Self.directoryError { try history.position(of: .beforeTurn(1)) } == .forkCutOutOfRange(.beforeTurn(1)))
    }

    @Test func aPositionInTheFoldedRangeIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)
        let cut = SessionForkCut.historyPosition(Self.checkpointPosition)

        #expect(Self.directoryError { try history.position(of: cut) } == .forkCutOutOfRange(cut))
    }

    @Test func thePositionJustAfterTheCheckpointIsInRange() throws {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)
        let cut = SessionForkCut.historyPosition(Self.turnAfterCompactionStart)

        #expect(try history.position(of: cut) == Self.turnAfterCompactionStart)
    }

    // MARK: - History positions

    @Test func aPositionAtTheEndOfTheHistoryIsInRange() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .historyPosition(Self.twoTurns.count)) == Self.twoTurns.count)
    }

    @Test func aPositionAfterTheEndOfTheHistoryIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)
        let cut = SessionForkCut.historyPosition(Self.twoTurns.count + 1)

        #expect(Self.directoryError { try history.position(of: cut) } == .forkCutOutOfRange(cut))
    }

    // MARK: - The calling tool call

    @Test func theCallingToolCallCutsBeforeTheLastRound() throws {
        let history = ForkCutHistory(entries: Self.runningToolTurn, runningAnswerStart: Self.runningToolTurnStart)

        #expect(try history.position(of: .callingToolCall) == Self.callingRoundPosition)
    }

    @Test func theCallingToolCallOfAnIdleSourceIsOutOfRange() {
        let history = ForkCutHistory(entries: Self.runningToolTurn, runningAnswerStart: nil)
        let error = Self.directoryError { try history.position(of: .callingToolCall) }

        #expect(error == .forkCutOutOfRange(.callingToolCall))
    }
}
