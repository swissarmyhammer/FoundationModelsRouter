import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The reducer of the session directory that maps the events of one session
/// to its `SessionState` and keeps its last summary (ROUTER-9).
///
/// The work events drive working and idle (user decision of 2026-10-21): a
/// session works from its first submission until the whole chain of work
/// ends, so it never reports idle in the middle of a tool loop. Only an
/// elicitation gives `needsInput`: a rule never asks (D64).
///
/// Each test drives a fresh ``SessionStateTracking`` with hand-built events:
/// no session runs.
@Suite("SessionStateTracking: the work state and the last summary of one session")
struct SessionStateTrackingTests {
    // MARK: - Constants

    /// The reply of the answers the tests give.
    private static let reply = "the work is done"

    /// The length of the long reply of the cut test: longer than
    /// ``SessionStateTracking/lastSummaryLength``.
    private static let longReplyLength = 600

    /// The tool of each run event the tests build.
    private static let tool = "jobs"

    /// The operation of each run event the tests build.
    private static let op = "run job"

    /// The correlation id of each run event the tests build.
    private static let correlationID = "run-1"

    /// The number of the first submission of a chain.
    private static let firstSubmissionNumber: UInt64 = 1

    /// The number of the second submission of a chain.
    private static let secondSubmissionNumber: UInt64 = 2

    /// The time of each tool invocation record the tests build, in seconds
    /// since 1970.
    private static let recordSeconds: TimeInterval = 100

    /// The token count of the context before the compaction the tests build.
    private static let tokensBeforeCompaction = 2

    // MARK: - Event builders

    /// The `elicitationRequested` of a form question with `id`.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: The event.
    private static func questionAsked(id: ULID) -> SessionEvent {
        .elicitationRequested(
            OperationEvent(
                tool: tool, op: op, correlationID: correlationID, kind: .elicitation, detail: "",
                elicitation: PendingElicitationFixtures.formRequest(elicitationId: id)))
    }

    /// The `elicitationEnded` of the question `id`, with a decline.
    ///
    /// - Parameter id: The id of the question.
    /// - Returns: The event.
    private static func questionEnded(id: ULID) -> SessionEvent {
        .elicitationEnded(ElicitationEnd(elicitationId: id, response: .decline))
    }

    /// The `answered` of a chain whose final reply is `reply`.
    ///
    /// - Parameter reply: The final reply.
    /// - Returns: The event.
    private static func answered(with reply: String) -> SessionEvent {
        .answered(
            SessionAnswer(reply: reply, mailIds: [], usage: nil, compactions: [], toolCalls: [], toolInvocations: []))
    }

    /// The `submissionStarted` of the submission `number`.
    ///
    /// - Parameter number: The number of the submission.
    /// - Returns: The event.
    private static func submissionStarted(number: UInt64) -> SessionEvent {
        .submissionStarted(SubmissionStart(submissionId: SubmissionID(number), mailIds: [], cause: .message))
    }

    /// The `submissionEnded` of the submission `number`.
    ///
    /// - Parameter number: The number of the submission.
    /// - Returns: The event.
    private static func submissionEnded(number: UInt64) -> SessionEvent {
        .submissionEnded(SubmissionEnd(submissionId: SubmissionID(number), usage: nil, finishReason: .completed))
    }

    /// A run event of `kind`.
    ///
    /// - Parameter kind: The kind of the run event.
    /// - Returns: The run event.
    private static func runEvent(kind: OperationEventKind) -> OperationEvent {
        OperationEvent(tool: tool, op: op, correlationID: correlationID, kind: kind, detail: "")
    }

    /// One event of each `SessionEvent` case other than
    /// `elicitationRequested`.
    private static var everyEventButAQuestion: [SessionEvent] {
        let record = ToolInvocationRecord(
            tool: tool, op: op, correlationID: correlationID, sessionID: .generate(),
            openedAt: Date(timeIntervalSince1970: recordSeconds))
        let detection = RepetitionDetection()
        return [
            .textDelta(reply), .textReset, .reasoningDelta(reply),
            .toolCall(id: correlationID, name: tool, argumentsJSON: "{}"),
            .toolStatus(id: correlationID, status: .completed, summary: reply, output: []),
            .toolInvocation(record, toolCallID: correlationID),
            .toolCallReport(
                ToolCallReport(
                    tool: tool, op: op, correlationID: correlationID, sessionID: record.sessionID,
                    attachments: [MountFixtures.firstAttachment])),
            .toolDisplay(
                ToolDisplayEvent(tool: tool, op: op, correlationID: correlationID, kind: .contentChunk(.text(reply)))),
            .entryRecorded(id: correlationID, kind: .response),
            .compactionStarted(CompactionStart(id: correlationID, reason: .requested)),
            .compaction(
                CompactionResult(
                    summary: reply, tokensBefore: tokensBeforeCompaction, tokensAfter: 1, stagesApplied: [])),
            .compactionFailed(CompactionFailure(id: correlationID, reason: .requested, outcome: .cancelled)),
            .discoveryPrimingFailed(.toolNotMounted(tool: tool)),
            .generationStalled(
                GenerationStall(
                    timeWithoutProgress: .seconds(1), timeInFlight: .seconds(1), visibility: .wholeAnswer,
                    lastProgress: .toolResult)),
            .submissionQueued(SubmissionID(firstSubmissionNumber)), submissionStarted(number: firstSubmissionNumber),
            submissionEnded(number: firstSubmissionNumber), answered(with: reply),
            .answerFailed(AnswerFailure(mailIds: [], reason: .cancelled)),
            .repetitionStopped(
                RepetitionStop(
                    generatedTokens: 0, countedLines: 0, newLines: 0, tokensWithoutNewLine: 0, detection: detection,
                    recovery: nil, repeatedToolCall: nil)),
            .reasoningStopped(
                ReasoningStop(
                    reasoningTokens: 0, limit: nil, passFinishReason: .completed, detection: detection, recovery: nil)),
            .runSettled(runEvent(kind: .completed)), .runMessage(runEvent(kind: .message)),
            .runProgress(runEvent(kind: .progress)),
            .generationCall(
                GenerationCallUsage(
                    tokensIn: 1, tokensOut: 1, finishReason: .completed, entryKind: .text, contextFill: 0)),
            .mailDeliveryPaused(MailDeliveryPause(limit: 1, heldMail: [runEvent(kind: .completed)])),
            .mailDelivered(MailID()), .cancelled(MailID()), .signalDone(SignalID()), .lost(MailID()),
            .workStarted, .workEnded, questionEnded(id: .generate()),
            .elicitationCompleted(ElicitationCompletion(elicitationId: .generate())),
        ]
    }

    /// A tracking that applied each of `events`, in order.
    ///
    /// - Parameter events: The events of the session.
    /// - Returns: The tracking.
    private static func tracking(after events: [SessionEvent]) -> SessionStateTracking {
        var tracking = SessionStateTracking()
        for event in events {
            tracking.apply(event: event)
        }
        return tracking
    }

    // MARK: - Working and idle

    @Test("a new session is idle and has no last summary")
    func aNewSessionIsIdle() {
        let tracking = SessionStateTracking()

        #expect(tracking.state == .idle)
        #expect(tracking.lastSummary == nil)
    }

    @Test("workStarted gives working")
    func workStartedGivesWorking() {
        #expect(Self.tracking(after: [.workStarted]).state == .working)
    }

    @Test("workEnded with no open question gives idle")
    func workEndedGivesIdle() {
        #expect(Self.tracking(after: [.workStarted, .workEnded]).state == .idle)
    }

    /// The production change that makes this test fail: the literal spec
    /// mapping, where `submissionEnded` gives idle. The first submission of
    /// the chain then ends the turn before the tool loop goes on.
    @Test("a chain of two submissions stays working until its work ends")
    func aChainOfTwoSubmissionsStaysWorking() {
        let chain: [SessionEvent] = [
            .workStarted,
            Self.submissionStarted(number: Self.firstSubmissionNumber),
            Self.submissionEnded(number: Self.firstSubmissionNumber),
            Self.submissionStarted(number: Self.secondSubmissionNumber),
            Self.submissionEnded(number: Self.secondSubmissionNumber),
            Self.answered(with: Self.reply),
        ]

        var tracking = SessionStateTracking()
        let states = chain.map { event in
            tracking.apply(event: event)
            return tracking.state
        }

        #expect(states.allSatisfy { $0 == .working })
    }

    // MARK: - The last summary

    @Test("answered keeps the reply as the last summary, and the work end then gives idle with it")
    func answeredKeepsTheReply() {
        let answering = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply)])
        let ended = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply), .workEnded])

        #expect(answering.state == .working)
        #expect(answering.lastSummary == Self.reply)
        #expect(ended.state == .idle)
        #expect(ended.lastSummary == Self.reply)
    }

    @Test("a reply of 600 characters is cut to its first 500 characters")
    func aLongReplyIsCutTo500Characters() {
        let longReply = String(repeating: "a", count: Self.longReplyLength - 1) + "z"

        let tracking = Self.tracking(after: [.workStarted, Self.answered(with: longReply)])

        #expect(tracking.lastSummary == String(longReply.prefix(SessionStateTracking.lastSummaryLength)))
        #expect(tracking.lastSummary?.count == SessionStateTracking.lastSummaryLength)
    }

    @Test("a later answer replaces the last summary")
    func aLaterAnswerReplacesTheLastSummary() {
        let later = "the second job is done"

        let tracking = Self.tracking(after: [
            .workStarted, Self.answered(with: Self.reply), Self.answered(with: later),
        ])

        #expect(tracking.lastSummary == later)
    }

    /// The production change that makes this test fail: an idle summary that
    /// gives the stored last summary in every state. The port documents
    /// `lastSummary` of `stateChanged` only for the idle state.
    @Test("the idle summary is the last summary while idle, and nil while working, needing input, or archived")
    func theIdleSummaryIsTheLastSummaryOnlyWhileIdle() {
        let answering = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply)])
        let idle = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply), .workEnded])
        let nextTurn = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply), .workEnded, .workStarted])
        let asking = Self.tracking(after: [
            .workStarted, Self.answered(with: Self.reply), Self.questionAsked(id: .generate()),
        ])
        var archived = idle
        archived.archive()

        #expect(answering.idleSummary == nil)
        #expect(idle.idleSummary == Self.reply)
        #expect(nextTurn.idleSummary == nil)
        #expect(asking.idleSummary == nil)
        #expect(archived.idleSummary == nil)
        #expect(archived.lastSummary == Self.reply)
    }

    // MARK: - Needs input

    @Test("elicitationRequested gives needsInput, also while the session works")
    func aQuestionGivesNeedsInput() {
        #expect(Self.tracking(after: [.workStarted, Self.questionAsked(id: .generate())]).state == .needsInput)
    }

    @Test("workEnded while a question is open keeps needsInput")
    func theWorkEndKeepsAnOpenQuestion() {
        let tracking = Self.tracking(after: [.workStarted, Self.questionAsked(id: .generate()), .workEnded])

        #expect(tracking.state == .needsInput)
    }

    @Test("the end of the only open question gives working while the session works, and idle when it has no work")
    func theEndOfTheOnlyQuestionLeavesNeedsInput() {
        let question = ULID.generate()

        let working = Self.tracking(after: [
            .workStarted, Self.questionAsked(id: question), Self.questionEnded(id: question),
        ])
        let idle = Self.tracking(after: [
            .workStarted, Self.questionAsked(id: question), .workEnded, Self.questionEnded(id: question),
        ])

        #expect(working.state == .working)
        #expect(idle.state == .idle)
    }

    @Test("the end of one of two open questions keeps needsInput")
    func theEndOfOneOfTwoQuestionsKeepsNeedsInput() {
        let first = ULID.generate()

        let tracking = Self.tracking(after: [
            .workStarted, Self.questionAsked(id: first), Self.questionAsked(id: .generate()),
            Self.questionEnded(id: first),
        ])

        #expect(tracking.state == .needsInput)
    }

    @Test("a completed URL question gives working again")
    func aCompletedQuestionGivesWorking() {
        let question = ULID.generate()

        let tracking = Self.tracking(after: [
            Self.questionAsked(id: question), .workEnded, .workStarted,
            .elicitationCompleted(ElicitationCompletion(elicitationId: question)),
        ])

        #expect(tracking.state == .working)
    }

    /// The production change that makes this test fail: a work end that
    /// reads only the questions of the events. A form answer sends no event
    /// that names its question, so the session's own list of open questions
    /// is what tells the tracking that no question is open any more.
    @Test("a work end after the open questions were replaced by none gives idle")
    func aWorkEndAfterTheQuestionsWereAnsweredGivesIdle() {
        var tracking = Self.tracking(after: [Self.questionAsked(id: .generate()), .workEnded, .workStarted])

        tracking.replaceOpenQuestions(with: [])
        tracking.apply(event: .workEnded)

        #expect(tracking.state == .idle)
    }

    @Test("a work end after the open questions were replaced by one gives needsInput")
    func aWorkEndWithAnOpenQuestionOfTheSessionGivesNeedsInput() {
        var tracking = Self.tracking(after: [.workStarted])

        tracking.replaceOpenQuestions(with: [.generate()])
        tracking.apply(event: .workEnded)

        #expect(tracking.state == .needsInput)
    }

    /// The production change that makes this test fail: any event other than
    /// a question that gives `needsInput`, for example a rule denial or a
    /// `default` arm that maps an unknown event to `needsInput` (D64).
    @Test("no event other than elicitationRequested gives needsInput, from idle or from working")
    func noOtherEventGivesNeedsInput() {
        let events = Self.everyEventButAQuestion

        let fromIdle = events.map { Self.tracking(after: [$0]).state }
        let fromWorking = events.map { Self.tracking(after: [.workStarted, $0]).state }

        #expect(!fromIdle.contains(.needsInput))
        #expect(!fromWorking.contains(.needsInput))
    }

    // MARK: - Archived

    @Test("an archive gives archived, and no later event changes it")
    func anArchiveIsFinal() {
        var tracking = Self.tracking(after: [.workStarted, Self.answered(with: Self.reply)])

        tracking.archive()
        let archived = tracking.state
        for event in Self.everyEventButAQuestion + [Self.questionAsked(id: .generate())] {
            tracking.apply(event: event)
        }

        #expect(archived == .archived)
        #expect(tracking.state == .archived)
        #expect(tracking.lastSummary == Self.reply)
    }
}
