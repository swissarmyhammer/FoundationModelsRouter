import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tasks ^1psqdm9 and ^qhgfajc: a lock must not cross over a tool call, only
/// over the call into the model.
///
/// Each session is a routed session over one ``LiveBackendContainer``, so each
/// answer goes through the production backend. Each pass of an SDK call is one
/// call into the model, and ``PassObservingModel`` holds its
/// ``FIFOGenerationLock`` for that one pass, as an MLX model does. A tool body
/// runs between two passes, so it holds nothing: another session over the same
/// model generates while the tool body runs, and the sessions take turns at
/// each pass. An in-band tool body that asks a session on the same model for
/// an answer gets it. The cancellation of an answer is held by
/// `NestedGenerationReentryTests`.
///
/// Each wait waits for an event: a semaphore that a tool body signals, a pass
/// that the model records, or a pass that waits for the lock. Each wait that a
/// regression can keep open is a ``BoundedWait``. A test opens every latch and
/// releases every step before it awaits an answer.
@Suite("A tool body holds no lock of the model (tasks ^1psqdm9, ^qhgfajc)")
struct ToolBodyHoldsNoLockTests {
    /// A tool whose body signals that it started, and then waits on a latch:
    /// the shape of a tool that waits for a person or for other work.
    private struct WaitingTool: Tool {
        let name = "waiting_tool"
        let description = "signals that it started, then waits until its latch opens"

        /// Signalled once when the body starts.
        let entered: AsyncSemaphore

        /// The latch the body waits on.
        let latch: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            entered.signal()
            await latch.waitUntilOpen()
            return arguments.value
        }
    }

    /// A tool whose body asks a child session for a whole answer, in band:
    /// the shape of an agent tool that waits inside its submission. It keeps
    /// the error the child throws, and answers with a fixed text, so the
    /// parent ends whatever the child does.
    private struct ChildAnswerTool: Tool {
        let name = "child_answer_tool"
        let description = "asks a child session for an answer, and keeps the error it throws"

        /// The session the body asks for an answer.
        let child: any RoutedSession

        /// Where the body keeps the error of the child.
        let refusal: ErrorBox

        func call(arguments: MountArguments) async throws -> String {
            do {
                return try await child.respond(to: ToolBodyHoldsNoLockTests.secondPrompt)
            } catch {
                refusal.store(error)
                return ToolBodyHoldsNoLockTests.refusedAnswer
            }
        }
    }

    /// Keeps one error that a tool body caught, so the test reads it after the
    /// answer ends.
    private final class ErrorBox: Sendable {
        /// The error, or `nil` while no body stored one.
        private let stored = Mutex<(any Error)?>(nil)

        /// The error, or `nil` while no body stored one.
        var error: (any Error)? { stored.withLock { $0 } }

        /// Keeps `error`.
        ///
        /// - Parameter error: The error the body caught.
        func store(_ error: any Error) {
            stored.withLock { $0 = error }
        }
    }

    /// What ``ChildAnswerTool`` answers when the child throws.
    private static let refusedAnswer = "the child refused"

    /// A declared background tool whose body waits on a latch, and then asks
    /// a child session for a whole answer.
    private struct BackgroundChildAnswerTool: Tool, BackgroundTool {
        let name = "background_child_answer_tool"
        let description = "in the background, waits for its latch, then asks a child session for an answer"

        /// The session the body asks for an answer.
        let child: any RoutedSession

        /// The latch the body waits on before it asks for the answer.
        let start: RunLatch

        /// Taken by the first call, which asks the child for the answer.
        let firstCall = FirstCallFlag()

        /// Every call goes to the background.
        var mount: ToolMount? { ToolMount(mode: .background) }

        /// A later call starts nothing and settles at once, inside this grace,
        /// so the call answers with its own output and is no mail. Without
        /// it, the scripted model calls the tool again in each delivery
        /// submission, and each call would start one more delivery.
        var inlineSettleGrace: TimeInterval { ToolBodyHoldsNoLockTests.laterCallSettleGrace }

        func call(arguments: MountArguments) async throws -> String {
            guard firstCall.take() else { return ToolBodyHoldsNoLockTests.nothingStarted }
            await start.waitUntilOpen()
            return try await child.respond(to: ToolBodyHoldsNoLockTests.secondPrompt)
        }
    }

    /// The session that a tool asks, set after the session exists: a tool
    /// goes into `makeSession` before that call returns the session.
    private final class SessionSlot: Sendable {
        /// The session, or `nil` before the test sets it.
        private let stored = Mutex<(any RoutedSession)?>(nil)

        /// The session. The test sets it before any answer starts.
        var session: any RoutedSession {
            get throws { try #require(stored.withLock { $0 }) }
        }

        /// Keeps `session`.
        ///
        /// - Parameter session: The session that the tool asks.
        func set(_ session: any RoutedSession) {
            stored.withLock { $0 = session }
        }
    }

    /// A tool whose body asks the session in `target`, its own session, for
    /// a whole answer, in band. It keeps the error, and answers with a fixed
    /// text.
    private struct OwnSessionAnswerTool: Tool {
        let name = "own_session_answer_tool"
        let description = "asks its own session for an answer, and keeps the error it throws"

        /// The session the body asks for an answer: its own session.
        let target: SessionSlot

        /// Where the body keeps the error.
        let refusal: ErrorBox

        func call(arguments: MountArguments) async throws -> String {
            do {
                return try await target.session.respond(to: ToolBodyHoldsNoLockTests.secondPrompt)
            } catch {
                refusal.store(error)
                return ToolBodyHoldsNoLockTests.refusedAnswer
            }
        }
    }

    /// A declared background tool whose body waits on a latch, and then asks
    /// the session in `target`, its own session, for a whole answer.
    private struct BackgroundOwnSessionAnswerTool: Tool, BackgroundTool {
        let name = "background_own_session_answer_tool"
        let description = "in the background, waits for its latch, then asks its own session for an answer"

        /// The session the body asks for an answer: its own session.
        let target: SessionSlot

        /// The latch the body waits on before it asks for the answer.
        let start: RunLatch

        /// Taken by the first call, which asks for the answer.
        let firstCall = FirstCallFlag()

        /// Every call goes to the background.
        var mount: ToolMount? { ToolMount(mode: .background) }

        /// See ``BackgroundChildAnswerTool/inlineSettleGrace``.
        var inlineSettleGrace: TimeInterval { ToolBodyHoldsNoLockTests.laterCallSettleGrace }

        func call(arguments: MountArguments) async throws -> String {
            guard firstCall.take() else { return ToolBodyHoldsNoLockTests.nothingStarted }
            await start.waitUntilOpen()
            return try await target.session.respond(to: ToolBodyHoldsNoLockTests.secondPrompt)
        }
    }

    /// What a tool body read of the task-locals of its model call.
    private struct ReadBindings: Sendable, Equatable {
        /// The session of the ambient ``ToolContext``.
        let toolContextSession: ULID?

        /// Whether ``SessionOwnWork/current`` names the session.
        let ownWorkNamesTheSession: Bool

        /// Whether ``SessionCallMark/current`` is the open mark of the
        /// session.
        let callMarkIsOpen: Bool

        /// The session of ``SubagentQuestionHost/session``.
        let questionHostSession: ULID?
    }

    /// Keeps what one tool body read, so the test reads it after the answer
    /// ends.
    private final class BindingsBox: Sendable {
        /// What the body read, or `nil` while no body ran.
        private let stored = Mutex<ReadBindings?>(nil)

        /// What the body read, or `nil` while no body ran.
        var read: ReadBindings? { stored.withLock { $0 } }

        /// Keeps `bindings`.
        ///
        /// - Parameter bindings: What the body read.
        func store(_ bindings: ReadBindings) {
            stored.withLock { $0 = bindings }
        }
    }

    /// A tool whose body reads the task-locals of its model call for the
    /// session in `target`, and keeps them.
    private struct BindingReadingTool: Tool {
        let name = "binding_reading_tool"
        let description = "reads the task-locals of its model call"

        /// The session of the model call.
        let target: SessionSlot

        /// Where the body keeps what it read.
        let bindings: BindingsBox

        func call(arguments: MountArguments) async throws -> String {
            let id = try target.session.id
            let bindings = ReadBindings(
                toolContextSession: ToolContext.current?.sessionID,
                ownWorkNamesTheSession: SessionOwnWork.current.contains(id),
                callMarkIsOpen: SessionCallMark.current?.isOpenCall(of: id) == true,
                questionHostSession: SubagentQuestionHost.session?.id)
            self.bindings.store(bindings)
            return arguments.value
        }
    }

    /// How long a call of ``BackgroundChildAnswerTool`` waits for its run to
    /// settle inline. Long enough for a run that starts nothing, and short.
    private static let laterCallSettleGrace: TimeInterval = 0.5

    /// The answer of each later call of ``BackgroundChildAnswerTool``.
    private static let nothingStarted = "nothing new started"

    /// The passes before the delivery submission of the parent: the two
    /// passes of its first submission (the tool call, then the answer), and
    /// the one pass of the run on the child.
    private static let passesBeforeDelivery = 3

    /// The prompt of the first session of a test.
    private static let firstPrompt = "a"

    /// The prompt of the second session of a test.
    private static let secondPrompt = "b"

    /// How many passes of one submission call a tool in the test of the turns.
    private static let loopingToolRounds = 3

    /// The temp-directory prefix of this suite.
    private static let tempDirPrefix = "ToolBodyHoldsNoLockTests"

    /// The text of each response in the transcript of `session`, in order.
    ///
    /// - Parameter session: The session to read. No submission of it may run,
    ///   so the read does not wait.
    /// - Returns: The response texts.
    private static func responseTexts(of session: any RoutedSession) async -> [String] {
        Array(await session.transcript).compactMap { entry in
            if case .response(let response) = entry {
                return WatchedText.text(of: response.segments)
            }
            return nil
        }
    }

    @Test("a tool body that waits holds nothing, so another session over the same model generates during it")
    func aToolBodyThatWaitsHoldsNothing() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let entered = AsyncSemaphore(value: 0)
        let toolLatch = RunLatch()
        let waiting = resolved.profile.standard.makeSession(tools: [WaitingTool(entered: entered, latch: toolLatch)])
        let other = resolved.profile.standard.makeSession()
        // The tool latch opens before the closes, also when the test throws
        // (rule T1): a close waits for the held tool body.
        defer { await SessionFixtureLifecycle.close([waiting, other], opening: [toolLatch]) }

        let waitingAnswerTask = Task { try await waiting.respond(to: Self.firstPrompt) }
        try await BoundedWait.run {
            try await RecordedWaitResult.wait(forPermitOf: entered, endingOnEndOf: waitingAnswerTask)
        }

        // The tool body waits now. The other session generates and answers.
        let otherAnswer = try await BoundedWait.value(of: Task { try await other.respond(to: Self.secondPrompt) })
        let passesDuringTheToolBody = fixture.passes.recorded.map(\.prompt)

        await toolLatch.open()
        let waitingAnswer = try await BoundedWait.value(of: waitingAnswerTask)

        #expect(passesDuringTheToolBody == [Self.firstPrompt, Self.secondPrompt])
        #expect(otherAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        #expect(waitingAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.secondPrompt, Self.firstPrompt])
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions with long tool loops over one model take turns at each generation, first in first out")
    func twoToolLoopsTakeTurnsPerGeneration() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: Self.loopingToolRounds, step: step)
        await fixture.latch.open()
        let passes = fixture.passes
        let lock = fixture.lock
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let first = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let second = resolved.profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        let passesPerSubmission = Self.loopingToolRounds + 1
        let allPasses = passesPerSubmission * 2
        // The step gets one permit for each pass of the two submissions
        // before the closes, also when the test throws (rule T1): a close
        // waits for a held pass.
        defer {
            await SessionFixtureLifecycle.close([first, second], releasing: [step], permits: allPasses)
        }

        let firstAnswerTask = Task { try await first.respond(to: Self.firstPrompt) }
        try await BoundedWait.run { try await passes.waitForPasses(1) }
        let secondAnswerTask = Task { try await second.respond(to: Self.secondPrompt) }

        // Release one pass at a time. Before each release, the next pass of
        // the other session waits for the lock: the tool body between two
        // passes of one session gives the lock to the other session. A pass
        // holds on its step, so the count of the passes is exact at each
        // read.
        for released in 1..<allPasses {
            try await BoundedWait.run { try await lock.waitForWaiters(1) }
            step.signal()
            try await BoundedWait.run { try await passes.waitForPasses(released + 1) }
            #expect(passes.recorded.count == released + 1)
        }
        step.signal()
        let firstAnswer = try await BoundedWait.value(of: firstAnswerTask)
        let secondAnswer = try await BoundedWait.value(of: secondAnswerTask)

        let turns = (0..<passesPerSubmission).flatMap { _ in [Self.firstPrompt, Self.secondPrompt] }
        #expect(passes.recorded.map(\.prompt) == turns)
        #expect(await fixture.observer.maximumActive == 1)
        #expect(firstAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(secondAnswer == PassObservingModel.answer(to: Self.secondPrompt))
        withExtendedLifetime(resolved) {}
    }

    @Test("an in-band tool body that asks a session on the same model for an answer is answered")
    func anInBandWaitForASessionOnTheSameModelIsAnswered() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])
        defer { await SessionFixtureLifecycle.close([parent, child]) }

        // A regression that parks the child behind the call of its parent
        // keeps this wait open until its limit.
        let parentAnswer = try await BoundedWait.value(of: Task { try await parent.respond(to: Self.firstPrompt) })

        #expect(refusal.error == nil)
        // The child generated inside the tool body of the parent.
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.secondPrompt, Self.firstPrompt])
        #expect(await Self.responseTexts(of: child) == [PassObservingModel.answer(to: Self.secondPrompt)])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        withExtendedLifetime(resolved) {}
    }

    /// The prompt of the answer the child runs on its own in the busy-child
    /// test.
    private static let childOwnPrompt = "c"

    /// The passes of the busy-child test: the first of the parent, the one of
    /// the child's own answer, the one of the answer the parent asked for,
    /// and the last of the parent.
    private static let busyChildPassCount = 4

    @Test("an in-band wait for a busy session on the same model is answered after the turn of that session")
    func anInBandWaitForABusySessionOnTheSameModelIsAnsweredAfterItsTurn() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let step = AsyncSemaphore(value: 0)
        let fixture = PassObservingFixture(toolRounds: 1, step: step)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let refusal = ErrorBox()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(tools: [ChildAnswerTool(child: child, refusal: refusal)])
        // The step gets one permit for each pass before the closes, also when
        // the test throws (rule T1): a close waits for a held pass.
        defer {
            await SessionFixtureLifecycle.close(
                [parent, child], releasing: [step], permits: Self.busyChildPassCount)
        }

        // The parent's first pass holds the lock, on its step.
        let parentAnswerTask = Task { try await parent.respond(to: Self.firstPrompt) }
        try await BoundedWait.run { try await fixture.passes.waitForPasses(1) }
        // The pump of the child runs its own answer, and its pass waits for
        // the lock.
        let childAnswerTask = Task { try await child.respond(to: Self.childOwnPrompt) }
        try await BoundedWait.run { try await fixture.lock.waitForWaiters(1) }

        // The tool body of the parent now asks the busy child for an answer.
        // The child answers it after its own answer.
        for _ in 0..<Self.busyChildPassCount { step.signal() }
        let parentAnswer = try await BoundedWait.value(of: parentAnswerTask)
        let childAnswer = try await BoundedWait.value(of: childAnswerTask)

        #expect(refusal.error == nil)
        #expect(
            fixture.passes.recorded.map(\.prompt)
                == [Self.firstPrompt, Self.childOwnPrompt, Self.secondPrompt, Self.firstPrompt])
        #expect(parentAnswer == PassObservingModel.answer(to: Self.firstPrompt))
        #expect(childAnswer == PassObservingModel.answer(to: Self.childOwnPrompt))
        withExtendedLifetime(resolved) {}
    }

    @Test("a background run generates on the same model after the answer that started it ended")
    func aBackgroundRunGeneratesOnTheSameModelAfterItsAnswerEnded() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let runStart = RunLatch()
        let child = resolved.profile.standard.makeSession()
        let parent = resolved.profile.standard.makeSession(
            tools: [BackgroundChildAnswerTool(child: child, start: runStart)])
        // The run latch opens before the closes, also when the test throws
        // (rule T1): a close waits for the held background run.
        defer { await SessionFixtureLifecycle.close([parent, child], opening: [runStart]) }

        // A stream of events ends with its answer, and does not wait for the
        // background runs of that answer. The run waits on its latch, so the
        // answer ends before the run asks the child for an answer.
        try await BoundedWait.run {
            for try await _ in await parent.streamEvents(to: Self.firstPrompt) {}
        }
        let runs = await parent.runPlane.backgroundRuns()

        // Only now does the run ask the child for an answer.
        await runStart.open()
        #expect(runs.count == 1)
        let token = try #require(runs.first?.completionToken)
        let runPlane = parent.runPlane
        let outcome = try await BoundedWait.run { await runPlane.wait(completionToken: token, seconds: nil) }

        var terminal: OperationEvent?
        if case .settled(let settled) = outcome {
            terminal = settled
        }
        #expect(terminal?.outcome == .succeeded)
        #expect(terminal?.detail == PassObservingModel.answer(to: Self.secondPrompt))

        // The terminal is mail: the pump of the parent delivers it in one
        // more submission, with no caller call, and then ends.
        try await BoundedWait.run { try await fixture.passes.waitForPasses(Self.passesBeforeDelivery + 1) }
        #expect(await parent.becomesIdle())
        // The two passes of the ended answer, then the pass of the run on the
        // child, then the passes of the delivery submission, which carries
        // the answer of the child.
        let prompts = fixture.passes.recorded.map(\.prompt)
        #expect(Array(prompts.prefix(Self.passesBeforeDelivery)) == [Self.firstPrompt, Self.firstPrompt, Self.secondPrompt])
        let deliveryPrompt = try #require(prompts.dropFirst(Self.passesBeforeDelivery).first)
        #expect(deliveryPrompt.contains(PassObservingModel.answer(to: Self.secondPrompt)))
        #expect(deliveryPrompt.contains(RoutedSessionActor.settledRunDeliveryPrompt))
        withExtendedLifetime(resolved) {}
    }

    @Test("an in-band tool body that waits for an answer of its own session is refused with the error of the session")
    func anInBandWaitForItsOwnSessionIsRefused() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let refusal = ErrorBox()
        let target = SessionSlot()
        let session = resolved.profile.standard.makeSession(tools: [OwnSessionAnswerTool(target: target, refusal: refusal)])
        defer { await SessionFixtureLifecycle.close([session]) }
        target.set(session)

        // The pump of the session runs one answer at a time, so the answer the
        // tool body waits for could start only after the answer of the tool
        // body. The refusal ends the wait at once.
        let answer = try await BoundedWait.value(of: Task { try await session.respond(to: Self.firstPrompt) })

        let refused = try #require(refusal.error as? RoutedSessionError)
        #expect(refused == .inBandWaitForOwnSession(sessionID: session.id))
        #expect(refused.errorDescription?.contains(session.id.description) == true)
        #expect(fixture.passes.recorded.map(\.prompt) == [Self.firstPrompt, Self.firstPrompt])
        #expect(answer == PassObservingModel.answer(to: Self.firstPrompt))
        withExtendedLifetime(resolved) {}
    }

    @Test("a background run that waits for its own session after the answer that started it ended is not refused")
    func aBackgroundRunWaitsForItsOwnSessionAfterItsAnswerEnded() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let runStart = RunLatch()
        let target = SessionSlot()
        let session = resolved.profile.standard.makeSession(
            tools: [BackgroundOwnSessionAnswerTool(target: target, start: runStart)])
        // The run latch opens before the close, also when the test throws
        // (rule T1): a close waits for the held background run.
        defer { await SessionFixtureLifecycle.close([session], opening: [runStart]) }
        target.set(session)

        // The stream ends with its answer, and does not wait for the run. The
        // run waits on its latch, so the answer ends before the run asks.
        try await BoundedWait.run {
            for try await _ in await session.streamEvents(to: Self.firstPrompt) {}
        }
        let runs = await session.runPlane.backgroundRuns()

        await runStart.open()
        #expect(runs.count == 1)
        let token = try #require(runs.first?.completionToken)
        let runPlane = session.runPlane
        let outcome = try await BoundedWait.run { await runPlane.wait(completionToken: token, seconds: nil) }

        var terminal: OperationEvent?
        if case .settled(let settled) = outcome {
            terminal = settled
        }
        #expect(terminal?.outcome == .succeeded)
        // The progress report of the run is mail, so it rides the prompt of
        // the answer in front of the run's own message.
        let detail = try #require(terminal?.detail)
        #expect(detail.hasPrefix(PassObservingModel.answerPrefix))
        #expect(detail.hasSuffix(Self.secondPrompt))
        withExtendedLifetime(resolved) {}
    }

    @Test("a tool body reads each task-local of its model call: the tool context, the own work, the call mark and the question host")
    func aToolBodyReadsEachTaskLocalOfItsModelCall() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture(toolRounds: 1)
        await fixture.latch.open()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let target = SessionSlot()
        let bindings = BindingsBox()
        let session = resolved.profile.standard.makeSession(
            tools: [BindingReadingTool(target: target, bindings: bindings)])
        defer { await SessionFixtureLifecycle.close([session]) }
        target.set(session)

        _ = try await BoundedWait.value(of: Task { try await session.respond(to: Self.firstPrompt) })

        let read = try #require(bindings.read)
        #expect(
            read
                == ReadBindings(
                    toolContextSession: session.id, ownWorkNamesTheSession: true, callMarkIsOpen: true,
                    questionHostSession: session.id))
        withExtendedLifetime(resolved) {}
    }
}
