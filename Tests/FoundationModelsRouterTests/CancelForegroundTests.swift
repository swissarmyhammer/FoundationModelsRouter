import Foundation
import FoundationModels
import FoundationModelsExtras
import Operations
import Testing

@testable import FoundationModelsRouter

/// A background run that asks one question through `ToolContext.elicit(_:)`
/// and ends with the action of the answer. The question links to the run, so a
/// test tells the question of a detached run from the question of a run that
/// is still inline.
@Generable
@Operation(verb: "ask", noun: "question", description: "Ask one question", mount: ToolMount(mode: .background))
struct AskQuestionRun {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension AskQuestionRun {
    /// The text of a body that runs outside a tool context.
    static let noContextText = "no tool context"

    /// Asks one form question and waits for its answer.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The action of the answer.
    /// - Throws: What `ToolContext.elicit(_:)` throws.
    func execute(in context: ShutdownRunFixtures.Context) async throws -> ShutdownRunFixtures.Output {
        guard let toolContext = ToolContext.current else {
            return ShutdownRunFixtures.Output(result: Self.noContextText)
        }
        let response = try await toolContext.elicit(
            PendingElicitationFixtures.formRequest(elicitationId: ULID.generate()))
        return ShutdownRunFixtures.Output(result: "answered: \(response.action.rawValue)")
    }
}

/// `RoutedSession/cancelForeground()`: the stop that a client asks with
/// `session/cancel`. It stops the foreground work of the session and spares
/// the runs that went to the background.
///
/// The runs are real: an `OperationTool` on a real run plane, started by a
/// scripted model, as in ``SuspendingCloseTests``. The settle period is on a
/// manual clock, so a call stays inline until the test ends its period. A run
/// whose call returned its pending envelope is a detached run. A run whose
/// call still waits is an inline run.
@Suite("A foreground cancel stops the inline work and spares the detached runs")
struct CancelForegroundTests {
    // MARK: - Constants

    /// The operation of a run that ignores the cancel and ends when the gate
    /// opens. The tests use it as the detached run.
    private static let detachedOp = "ignore cancel"

    /// The operation of a run that ends only at its cancel. The tests use it
    /// as the inline run: when it ends, the cancel reached it.
    private static let inlineOp = "swallow cancel"

    /// The operation of a run that asks one question.
    private static let askOp = "ask question"

    /// The prompt of the answer that the session takes after a foreground
    /// cancel.
    private static let followUpPrompt = "and now?"

    /// The count of the questions of one run.
    private static let oneQuestion = 1

    /// The count of the questions of the detached run and of the inline run.
    private static let twoQuestions = 2

    // MARK: - Helpers

    /// Waits until the run plane of `actor` holds `count` open questions.
    ///
    /// - Parameters:
    ///   - count: The count of the questions.
    ///   - actor: The session.
    ///   - answering: The answer whose end is the failure event.
    /// - Throws: ``FailureEventCameFirst`` when the answer ended first.
    private static func awaitOpenQuestions(
        _ count: Int, on actor: RoutedSessionActor, ending answering: Task<String, any Error>
    ) async throws {
        try await actor.idleChanges.wait(
            until: { await actor.runPlane.openElicitations().count >= count }, endingOnEndOf: answering)
    }

    /// Waits until the run plane of `actor` holds no open run.
    private static func awaitNoOpenRun(on actor: RoutedSessionActor) async throws {
        try await actor.idleChanges.wait(until: { await actor.runPlane.backgroundRuns().isEmpty })
    }

    /// The completion tokens of the open runs of `actor`.
    private static func openRunTokens(of actor: RoutedSessionActor) async -> [String] {
        await actor.runPlane.backgroundRuns().map(\.completionToken)
    }

    /// The session of `recording` as the actor, which shows its run plane.
    private static func actor(of recording: ShutdownRecording) throws -> RoutedSessionActor {
        try #require(recording.session as? RoutedSessionActor)
    }

    /// A submission with one detached run that asks a question and one inline
    /// run that asks a question, a feed of the session, and the id of the
    /// question of the detached run.
    private struct TwoQuestions {
        /// The recording of the session.
        let recording: ShutdownRecording

        /// The session of the recording.
        let actor: RoutedSessionActor

        /// The task of the answer.
        let answering: Task<String, any Error>

        /// The feed of the session, from before the answer.
        var feed: AsyncStream<SessionOutput>.Iterator

        /// The id of the question of the detached run.
        let detachedQuestion: ULID

        /// The id of the question of the inline run.
        let inlineQuestion: ULID
    }

    /// Makes a recording of two question runs, and brings the first run
    /// past the settle period with its question open, and the second call
    /// inline with its question open.
    ///
    /// - Returns: The state of the two questions. The caller ends the
    ///   recording.
    /// - Throws: What the make of the recording throws, or
    ///   ``FailureEventCameFirst`` when the answer ended first.
    private static func askTwoQuestions() async throws -> TwoQuestions {
        let recording = try await ShutdownRecording.make(calling: [askOp, askOp])
        let actor = try actor(of: recording)
        let feed = await recording.session.streamSessionEvents().makeAsyncIterator()
        let answering = recording.startAnswering()
        try await recording.awaitInlineCall(of: answering)
        try await awaitOpenQuestions(oneQuestion, on: actor, ending: answering)
        let detached = try #require(await actor.runPlane.openElicitations().first).elicitationId
        recording.endSettlePeriod()
        try await recording.awaitInlineCall(of: answering)
        try await awaitOpenQuestions(twoQuestions, on: actor, ending: answering)
        let inline = try #require(await actor.runPlane.openElicitations().last).elicitationId
        return TwoQuestions(
            recording: recording, actor: actor, answering: answering, feed: feed, detachedQuestion: detached,
            inlineQuestion: inline)
    }

    /// Whether `outputs` hold the end of an answer by a cancel.
    private static func holdsCancelledAnswer(_ outputs: [SessionOutput]) -> Bool {
        outputs.contains { output in
            guard case .answerFailed(let failure) = output.event else { return false }
            return failure.reason == .cancelled
        }
    }

    // MARK: - The inline work

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that does not stop the model work of the submission.
    @Test("a foreground cancel ends the running answer as cancelled")
    func foregroundCancelEndsTheAnswerAsCancelled() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.inlineOp])
        defer { await recording.end() }
        var feed = await recording.session.streamSessionEvents().makeAsyncIterator()
        let answering = recording.startAnswering()
        try await recording.awaitInlineCall(of: answering)

        let signal = recording.session.cancelForeground()
        let outputs = await SessionWorkEventTests.outputs(from: &feed, through: { $0 == .signalDone(signal) })

        #expect(Self.holdsCancelledAnswer(outputs))
    }

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that stops the model work and leaves the run of the inline call to
    /// go on behind its pending envelope. The body of this run ends only at
    /// its own cancel, so the run stays open then.
    @Test("a foreground cancel stops the run of a call that still waits inline")
    func foregroundCancelStopsTheInlineRun() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.inlineOp])
        defer { await recording.end() }
        let actor = try Self.actor(of: recording)
        let answering = recording.startAnswering()
        try await recording.awaitInlineCall(of: answering)

        let signal = recording.session.cancelForeground()
        _ = try await recording.session.awaitTerminal(of: signal)
        try await Self.awaitNoOpenRun(on: actor)

        #expect(await Self.openRunTokens(of: actor).isEmpty)
    }

    // MARK: - The detached runs

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that cancels every run of the run plane, as `cancelAll()` does.
    @Test("a foreground cancel leaves the detached run open and stops only the inline run")
    func foregroundCancelSparesTheDetachedRun() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.detachedOp, Self.inlineOp])
        defer { await recording.end() }
        let actor = try Self.actor(of: recording)
        _ = try await SuspendingCloseTests.openTwoRuns(in: recording)
        let detached = try #require(await Self.openRunTokens(of: actor).first)

        let signal = recording.session.cancelForeground()
        _ = try await recording.session.awaitTerminal(of: signal)
        // The inline run ends only at its cancel, so the wait ends when the
        // cancel reached it.
        try await actor.idleChanges.wait(until: { await Self.openRunTokens(of: actor) == [detached] })

        #expect(await Self.openRunTokens(of: actor) == [detached])
    }

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that settles the detached run, so its journal holds a cancel and not
    /// the result of its body.
    @Test("the detached run of a foreground cancel still completes with its result in the journal")
    func detachedRunCompletesAfterAForegroundCancel() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.detachedOp, Self.inlineOp])
        defer { await recording.end() }
        let actor = try Self.actor(of: recording)
        let answering = try await SuspendingCloseTests.openTwoRuns(in: recording)
        let signal = recording.session.cancelForeground()
        _ = try await recording.session.awaitTerminal(of: signal)
        _ = try? await answering.value

        await recording.gate.open()
        try await Self.awaitNoOpenRun(on: actor)

        #expect(try await recording.statuses().values.contains(.completed(.succeeded)))
    }

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that takes the open claims of the host, as `close()` does.
    @Test("a foreground cancel keeps the claims of the host on the runs of a restored session")
    func foregroundCancelKeepsTheClaims() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.inlineOp, Self.inlineOp])
        defer { await recording.end() }
        let answering = try await SuspendingCloseTests.openTwoRuns(in: recording)
        await SuspendingCloseTests.suspendAndClose(recording, ending: answering)
        let keys = try await recording.statuses().keys
        let tree = try await SuspendingCloseTests.restoreClaimingEveryRun(of: recording)
        defer { await SessionFixtureLifecycle.close(tree) }

        let signal = tree.root.cancelForeground()
        _ = try await tree.root.awaitTerminal(of: signal)
        var accepted: [Bool] = []
        for key in keys {
            accepted.append(await tree.root.completeClaimedRun(key, outcome: .succeeded, detail: nil))
        }

        #expect(accepted == [true, true])
    }

    // MARK: - The questions

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that leaves the question of the inline run to the sweep that never
    /// runs, so no end is sent.
    @Test("a foreground cancel ends the question of the inline run, and only that question")
    func foregroundCancelEndsTheInlineQuestion() async throws {
        var asked = try await Self.askTwoQuestions()
        defer { await asked.recording.end() }

        let signal = asked.recording.session.cancelForeground()
        let outputs = await SessionWorkEventTests.outputs(from: &asked.feed, through: { $0 == .signalDone(signal) })

        #expect(PendingElicitationFixtures.ends(in: outputs).map(\.end.elicitationId) == [asked.inlineQuestion])
    }

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that ends every open question, as `cancelAll()` does.
    @Test("a foreground cancel leaves the question of the detached run open")
    func foregroundCancelKeepsTheDetachedQuestion() async throws {
        var asked = try await Self.askTwoQuestions()
        defer { await asked.recording.end() }

        let signal = asked.recording.session.cancelForeground()
        _ = await SessionWorkEventTests.outputs(from: &asked.feed, through: { $0 == .signalDone(signal) })

        #expect(await asked.actor.runPlane.openElicitations().map(\.elicitationId) == [asked.detachedQuestion])
    }

    // MARK: - The other cancels and the later mail

    /// The production change that makes this test fail: a `cancelAll()` that
    /// spares the detached runs.
    @Test("cancelAll() still stops the detached run")
    func cancelAllStillStopsTheDetachedRun() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.detachedOp, Self.inlineOp])
        defer { await recording.end() }
        let actor = try Self.actor(of: recording)
        _ = try await SuspendingCloseTests.openTwoRuns(in: recording)

        let signal = recording.session.cancelAll()
        _ = try await recording.session.awaitTerminal(of: signal)
        try await Self.awaitNoOpenRun(on: actor)

        #expect(await Self.openRunTokens(of: actor).isEmpty)
    }

    /// The production change that makes this test fail: a `cancelForeground()`
    /// that leaves the queue closed or the pump stopped.
    @Test("the session takes later mail after a foreground cancel")
    func sessionTakesMailAfterAForegroundCancel() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.inlineOp])
        defer { await recording.end() }
        let answering = recording.startAnswering()
        try await recording.awaitInlineCall(of: answering)
        let signal = recording.session.cancelForeground()
        _ = try await recording.session.awaitTerminal(of: signal)
        _ = try? await answering.value

        // The script calls the tool again, so the new answer has its own
        // inline call. The test ends its settle period, and the answer ends.
        let session = recording.session
        let following = Task { try await session.respond(to: Self.followUpPrompt) }
        try await recording.awaitInlineCall(of: following)
        recording.endSettlePeriod()

        #expect(try await !following.value.isEmpty)
    }
}
