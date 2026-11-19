import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The rule that maps the cut of a fork to a position in the history of its
/// source (D205, ``ForkCutHistory``): the turns, the running turn, the
/// folded range of a compaction and the tool call that asks for the fork.
@Suite struct ForkCutHistoryTests {
    /// A prompt that delivers one user message or one directory message: the
    /// start of one turn.
    private static let turn = ForkCutHistory.Entry.prompt(turns: 1)

    /// A prompt that delivers no user message and no directory message: a
    /// continuation, or a prompt of run mail. It starts no turn.
    private static let continuation = ForkCutHistory.Entry.prompt(turns: 0)

    /// The history of two complete turns: the instructions, then a prompt
    /// and a response for each turn.
    private static let twoTurns: [ForkCutHistory.Entry] = [.other, turn, .other, turn, .other]

    /// The position of the prompt of the second turn of ``twoTurns``.
    private static let secondTurnStart = 3

    /// The history of two turns, a compaction that folds both, and one turn
    /// after the compaction.
    private static let compactedHistory: [ForkCutHistory.Entry] = [
        .other, turn, .other, turn, .other, .compactionCheckpoint, turn, .other,
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
        .other, turn, .other, turn, .toolCalls, .other, continuation, .toolCalls,
    ]

    /// The position where the running answer of ``runningToolTurn`` started.
    private static let runningToolTurnStart = 3

    /// The position of the last round of ``runningToolTurn``.
    private static let callingRoundPosition = 7

    /// The history of a turn whose answer goes on in a continuation prompt,
    /// then a second turn.
    private static let continuedTurn: [ForkCutHistory.Entry] = [
        .other, turn, .toolCalls, .other, continuation, .other, turn, .other,
    ]

    /// The position of the prompt of the second turn of ``continuedTurn``.
    private static let turnAfterContinuationStart = 6

    /// The history of one prompt that delivers two user messages, then one
    /// more turn.
    private static let batchHistory: [ForkCutHistory.Entry] = [
        .other, .prompt(turns: 2), .other, turn, .other,
    ]

    /// The position of the prompt of the batch of ``batchHistory``.
    private static let batchStart = 1

    /// The position of the prompt of the turn after the batch of
    /// ``batchHistory``: turn 2, because the batch holds turns 0 and 1.
    private static let turnAfterBatchStart = 3

    /// The router id of the recorded events of the tests.
    private static let routerID = ULID()

    /// The session id of the recorded events of the tests.
    private static let sessionID = ULID()

    // MARK: - Recorded events

    /// One recorded event of the source of the tests.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - entry: The entry of the event, or `nil`.
    /// - Returns: The event.
    private static func event(_ kind: TranscriptEvent.Kind, entry: TranscriptEntryPayload? = nil) -> TranscriptEvent {
        TranscriptEvent(routerId: routerID, sessionId: sessionID, seq: 0, ts: Date(), kind: kind, entry: entry)
    }

    /// The recorded `.prompt` event of a submission that delivered `mail`.
    ///
    /// - Parameter mail: The delivered mail, in take order.
    /// - Returns: The event.
    private static func prompt(delivering mail: [Mail]) -> TranscriptEvent {
        Self.event(.prompt, entry: MailRecordSegment.eventPayload(of: mail.map(MailRecord.mailDelivered)))
    }

    /// The recorded `.toolCalls` event of one call of `toolName`.
    ///
    /// - Parameter toolName: The name of the tool.
    /// - Returns: The event.
    private static func toolCalls(of toolName: String) -> TranscriptEvent {
        let call = ToolCallPayload(id: "\(toolName)-call", toolName: toolName, argumentsJSON: "{}")
        return Self.event(.toolCalls, entry: TranscriptEntryPayload(entryId: "\(toolName)-calls", toolCalls: [call]))
    }

    /// A user message.
    private static var userMessage: Mail {
        Mail(sender: .user, body: .userMessage(prompt: "hello", options: UserMessageOptions()))
    }

    /// A message of another session that the directory delivered.
    private static var directoryMessage: Mail {
        let sender = ULID()
        return Mail(sender: .session(sender), body: .agentMessage(from: sender, content: "from a session"))
    }

    /// A mail of a background run.
    private static var runMail: Mail {
        let event = MailQueueFixtures.progressEvent(detail: "progress")
        return Mail(sender: .run(correlationID: event.correlationID), body: .runEvent(event))
    }

    /// The recorded events of one user message and the response to it.
    private static var answeredUserMessage: [TranscriptEvent] {
        [prompt(delivering: [userMessage]), event(.response)]
    }

    /// The turn starts of the recorded history of `events`.
    ///
    /// - Parameter events: The recorded events of a source.
    /// - Returns: The position of the prompt of each turn.
    private static func recordedTurnStarts(of events: [TranscriptEvent]) -> [Int] {
        ForkCutHistory(entries: ForkCutHistory.recordedEntries(of: events), runningAnswerStart: nil).turnStarts
    }

    @Test func aRecordedContinuationPromptIsNotATurn() {
        let events = Self.answeredUserMessage + [Self.prompt(delivering: []), Self.event(.response)]

        #expect(Self.recordedTurnStarts(of: events) == [0])
    }

    @Test func aRecordedRunMailPromptIsNotATurn() {
        let events = Self.answeredUserMessage + [Self.prompt(delivering: [Self.runMail])]

        #expect(Self.recordedTurnStarts(of: events) == [0])
    }

    @Test func aRecordedDirectoryMessageIsATurn() {
        let events = Self.answeredUserMessage + [Self.prompt(delivering: [Self.directoryMessage])]

        #expect(Self.recordedTurnStarts(of: events) == [0, 2])
    }

    @Test func aRecordedBatchOfTwoUserMessagesIsTwoTurns() {
        let events = [Self.prompt(delivering: [Self.userMessage, Self.userMessage]), Self.event(.response)]

        #expect(Self.recordedTurnStarts(of: events) == [0, 0])
    }

    @Test func aMessageThatTheSourceSendsIsNotATurn() {
        let events = [
            Self.prompt(delivering: [Self.userMessage]), Self.toolCalls(of: "sessions"), Self.event(.toolOutput),
            Self.event(.response),
        ]

        #expect(Self.recordedTurnStarts(of: events) == [0])
    }

    // MARK: - The running submission

    @Test func theRunningPromptCountsTheTurnsOfItsMail() {
        let entries = ForkCutHistory.runningEntries(
            [TranscriptFixtures.makeInstructions(), .prompt(Transcript.Prompt(segments: []))],
            delivering: [Self.userMessage, Self.directoryMessage, Self.runMail])

        #expect(entries == [.other, .prompt(turns: 2)])
    }

    @Test func aRunningContinuationPromptIsNotATurn() {
        let entries = ForkCutHistory.runningEntries([.prompt(Transcript.Prompt(segments: []))], delivering: [])

        #expect(entries == [Self.continuation])
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

    @Test func afterARunningTurnIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: Self.secondTurnStart)

        let error = await DirectoryErrorCapture.error { try history.position(of: .afterTurn(1)) }

        #expect(error == .forkCutOutOfRange(.afterTurn(1)))
    }

    @Test func beforeTheSecondTurnIsItsPrompt() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(1)) == Self.secondTurnStart)
    }

    @Test func beforeARunningTurnIsItsPrompt() throws {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: Self.secondTurnStart)

        #expect(try history.position(of: .beforeTurn(1)) == Self.secondTurnStart)
    }

    @Test func aTurnIndexThatDoesNotExistIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        let error = await DirectoryErrorCapture.error { try history.position(of: .beforeTurn(2)) }

        #expect(error == .forkCutOutOfRange(.beforeTurn(2)))
    }

    @Test func aNegativeTurnIndexIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)

        let error = await DirectoryErrorCapture.error { try history.position(of: .afterTurn(-1)) }

        #expect(error == .forkCutOutOfRange(.afterTurn(-1)))
    }

    // MARK: - Continuations and batches

    @Test func aContinuationPromptStaysInTheTurnOfItsAnswer() throws {
        let history = ForkCutHistory(entries: Self.continuedTurn, runningAnswerStart: nil)

        #expect(try history.position(of: .afterTurn(0)) == Self.turnAfterContinuationStart)
    }

    @Test func beforeTheSecondMailOfABatchIsThePromptOfTheBatch() throws {
        let history = ForkCutHistory(entries: Self.batchHistory, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(1)) == Self.batchStart)
    }

    @Test func afterTheFirstMailOfABatchIsTheEndOfTheAnswerToTheBatch() throws {
        let history = ForkCutHistory(entries: Self.batchHistory, runningAnswerStart: nil)

        #expect(try history.position(of: .afterTurn(0)) == Self.turnAfterBatchStart)
    }

    @Test func theTurnAfterABatchCountsEachMailOfTheBatch() throws {
        let history = ForkCutHistory(entries: Self.batchHistory, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(2)) == Self.turnAfterBatchStart)
    }

    // MARK: - Compaction

    @Test func aTurnAfterTheCompactionKeepsItsIndexAmongTheFoldedTurns() throws {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        #expect(try history.position(of: .beforeTurn(Self.turnAfterCompaction)) == Self.turnAfterCompactionStart)
    }

    @Test func afterATurnThatTheCompactionFoldedIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        let error = await DirectoryErrorCapture.error { try history.position(of: .afterTurn(1)) }

        #expect(error == .forkCutOutOfRange(.afterTurn(1)))
    }

    @Test func beforeATurnThatTheCompactionFoldedIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)

        let error = await DirectoryErrorCapture.error { try history.position(of: .beforeTurn(1)) }

        #expect(error == .forkCutOutOfRange(.beforeTurn(1)))
    }

    @Test func aPositionInTheFoldedRangeIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.compactedHistory, runningAnswerStart: nil)
        let cut = SessionForkCut.historyPosition(Self.checkpointPosition)

        let error = await DirectoryErrorCapture.error { try history.position(of: cut) }

        #expect(error == .forkCutOutOfRange(cut))
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

    @Test func aPositionAfterTheEndOfTheHistoryIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.twoTurns, runningAnswerStart: nil)
        let cut = SessionForkCut.historyPosition(Self.twoTurns.count + 1)

        let error = await DirectoryErrorCapture.error { try history.position(of: cut) }

        #expect(error == .forkCutOutOfRange(cut))
    }

    // MARK: - The calling tool call

    @Test func theCallingToolCallCutsBeforeTheLastRound() throws {
        let history = ForkCutHistory(entries: Self.runningToolTurn, runningAnswerStart: Self.runningToolTurnStart)

        #expect(try history.position(of: .callingToolCall) == Self.callingRoundPosition)
    }

    @Test func theCallingToolCallOfAnIdleSourceIsOutOfRange() async {
        let history = ForkCutHistory(entries: Self.runningToolTurn, runningAnswerStart: nil)

        let error = await DirectoryErrorCapture.error { try history.position(of: .callingToolCall) }

        #expect(error == .forkCutOutOfRange(.callingToolCall))
    }
}
