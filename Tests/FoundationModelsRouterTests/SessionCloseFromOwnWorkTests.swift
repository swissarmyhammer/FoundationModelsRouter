import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@_spi(Testing) @testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^3jpewc9: ``RoutedSession/close()`` that the own work of
/// the session calls.
///
/// A tool call of the session, or the body of a background run of the
/// session, can call ``RoutedSession/close()`` of that same session. Close
/// waits for all work of the session, and that work includes the caller. So
/// close then starts the close and returns at once, and the close ends after
/// the work returns. A caller that is not the work of the session gets the
/// usual contract: when close returns, the session is closed.
///
/// Everything runs against the scripted ``BackgroundingBackend``, so the
/// suite needs no network and no GPU. The tests read the order of the steps,
/// not a clock. A close that waits for its own caller never returns, and a
/// hang is not a failure that a test can show. So each test of a close from
/// the own work passes only when the close returns early.
@Suite("close() from the own work of a session returns at once, and the close ends after that work")
struct SessionCloseFromOwnWorkTests {
    // MARK: - Fixtures

    /// The ways that a tool body calls ``RoutedSession/close()``.
    enum CloseRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// The tool body calls close itself.
        case direct

        /// The tool body starts a `Task {}` that calls close, and waits for
        /// that task. The task copies the task-locals of the tool body, so
        /// it is also the own work of the session.
        case taskOfTheTool

        var testDescription: String {
            switch self {
            case .direct: "close() in the tool body"
            case .taskOfTheTool: "close() in a Task {} of the tool body"
            }
        }

        /// Closes `session` by this route.
        ///
        /// - Parameter session: The session to close.
        func close(_ session: any RoutedSession) async {
            switch self {
            case .direct:
                await session.close()
            case .taskOfTheTool:
                await Task { await session.close() }.value
            }
        }
    }

    /// The session that a ``ClosingTool`` closes, the gates that its body
    /// waits on, and the steps that its body records.
    ///
    /// The `Mutex` values are the synchronization the `Sendable` conformance
    /// rests on. A tool is threaded into the session before the session
    /// exists, so the test sets the target after the session exists, and
    /// before any answer starts.
    final class CloseProbe: Sendable {
        /// The session that the tool body closes.
        private let storedTarget: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// The steps, in the order they occurred.
        private let storedSteps: Mutex<[String]> = Mutex([])

        /// The gate that the tool body waits on before it calls close.
        let mayStartClose = RunLatch()

        /// Sent when the call of close in the tool body returned.
        let closeReturned = AwaitedEvent()

        /// The gate that the tool body waits on after close returned.
        let mayReturn = RunLatch()

        /// Sent when the tool body is about to return.
        let workReturns = AwaitedEvent()

        /// The session that the tool body closes, or `nil` before the test
        /// set it.
        var target: (any RoutedSession)? {
            storedTarget.withLock { $0 }
        }

        /// The steps, in order.
        var steps: [String] {
            storedSteps.withLock { $0 }
        }

        /// Sets the session that the tool body closes.
        ///
        /// - Parameter session: The session.
        func setTarget(_ session: any RoutedSession) {
            storedTarget.withLock { $0 = session }
        }

        /// Records `step`.
        ///
        /// - Parameter step: The step.
        func record(_ step: String) {
            storedSteps.withLock { $0.append(step) }
        }
    }

    /// A tool whose body closes the target session of its probe.
    ///
    /// With no ``mount`` it declares nothing, so the session mounts it
    /// run-to-completion: the body runs in the answer that called it. With
    /// ``SessionCloseFromOwnWorkTests/backgroundMount`` the call hands back a
    /// pending envelope at once, and the body runs as a background run.
    struct ClosingTool: Tool, BackgroundTool {
        let name = "closing-probe"
        let description = "test-only tool that closes a routed session"

        /// The target, the gates and the steps of the body.
        let probe: CloseProbe

        /// How the body calls close.
        let route: CloseRoute

        /// The mount this tool declares for itself, or `nil` to declare none.
        var mount: ToolMount?

        /// No wait: a background call answers with its pending envelope at
        /// once.
        var inlineSettleGrace: TimeInterval { 0 }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await probe.mayStartClose.waitUntilOpen()
            guard let session = probe.target else { return SessionCloseFromOwnWorkTests.noTargetOutput }
            await route.close(session)
            probe.record(SessionCloseFromOwnWorkTests.closeReturnedStep)
            probe.closeReturned.signal()
            await probe.mayReturn.waitUntilOpen()
            probe.workReturns.signal()
            return SessionCloseFromOwnWorkTests.toolOutput
        }
    }

    // MARK: - Constants

    /// The output of a ``ClosingTool`` call.
    static let toolOutput = "the session is told to close"

    /// The output of a ``ClosingTool`` call when the test set no target, so
    /// a misbuilt fixture reads as a wrong answer rather than as a pass.
    static let noTargetOutput = "no target session"

    /// The step that a ``ClosingTool`` body records when close returned.
    static let closeReturnedStep = "close returned"

    /// The step that a run body of the parent records when it ended.
    static let parentRunEndedStep = "parent run body ended"

    /// The prompt that starts the answer that calls the tool.
    private static let prompt = "close the session"

    /// The mount of a background ``ClosingTool``.
    private static let backgroundMount = ToolMount(mode: .background, timeout: nil)

    // MARK: - Helpers

    /// Makes a session with one ``ClosingTool``, and makes that session the
    /// target of `probe`.
    ///
    /// - Parameters:
    ///   - probe: The probe of the tool.
    ///   - route: How the tool body calls close.
    ///   - mount: The mount of the tool, or `nil` for a run-to-completion
    ///     tool.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        probe: CloseProbe, route: CloseRoute, mount: ToolMount?
    ) async throws -> BackgroundingSessionFixture {
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: "SessionCloseFromOwnWorkTests",
            tools: [ClosingTool(probe: probe, route: route, mount: mount)])
        probe.setTarget(fixture.session)
        return fixture
    }

    /// Reads `events` until the stream ends.
    ///
    /// - Parameter events: The stream of ``RoutedSession/streamSessionEvents()``.
    private static func readToTheEnd(of events: AsyncStream<SessionOutput>) async {
        for await _ in events {}
    }

    /// Asserts that `session` is closed: it refuses new mail, no pump runs,
    /// no background run is open, and an idle wait returns `false` at once.
    ///
    /// - Parameter session: The session.
    private static func expectClosed(_ session: any RoutedSession) async {
        #expect(throws: MailRefusal.closed) {
            try session.send("late message")
        }
        #expect(await !session.isPumpRunning)
        #expect(await session.runPlane.backgroundRuns().isEmpty)
        #expect(await !session.awaitIdle())
    }

    // MARK: - The own work of the session

    /// The production change that makes this test hang: a close that does
    /// not return early for a run body of its own session. The close then
    /// waits for the body, and the body waits for the close.
    @Test(
        "a background run body that calls close() gets the return at once, and the close ends after the body returns",
        arguments: CloseRoute.allCases)
    @MainActor
    func aRunBodyThatClosesItsSessionGetsTheReturnAtOnce(route: CloseRoute) async throws {
        let probe = CloseProbe()
        let fixture = try await Self.makeFixture(probe: probe, route: route, mount: Self.backgroundMount)
        let events = await fixture.session.streamSessionEvents()

        // The answer hands back the pending envelope of the run, and only
        // then does the run body call close, so the close finds no answer.
        let answer = try await fixture.session.respond(to: Self.prompt)
        #expect(PendingRunEnvelope.makeDecoded(fromRendered: answer) != nil)
        await probe.mayStartClose.open()

        try await probe.closeReturned.wait()
        await probe.mayReturn.open()
        try await probe.workReturns.wait()
        await Self.readToTheEnd(of: events)
        await fixture.session.close()

        #expect(probe.steps == [Self.closeReturnedStep])
        await Self.expectClosed(fixture.session)
        await fixture.end()
    }

    /// The production change that makes this test hang: a close that does
    /// not return early for a tool call of its own session. The close then
    /// waits for the pump, the pump waits for the answer, and the answer
    /// waits for the tool.
    @Test(
        "a synchronous tool call inside an answer that calls close() gets the return at once, and the close ends after the tool returns",
        arguments: CloseRoute.allCases)
    @MainActor
    func aToolCallThatClosesItsSessionGetsTheReturnAtOnce(route: CloseRoute) async throws {
        let probe = CloseProbe()
        let fixture = try await Self.makeFixture(probe: probe, route: route, mount: nil)
        let events = await fixture.session.streamSessionEvents()
        await probe.mayStartClose.open()

        let answering = Task { try await fixture.session.respond(to: Self.prompt) }
        try await probe.closeReturned.wait()
        await probe.mayReturn.open()
        try await probe.workReturns.wait()
        // The close stopped the answer that called the tool.
        await #expect(throws: CancellationError.self) {
            try await answering.value
        }
        await Self.readToTheEnd(of: events)
        await fixture.session.close()

        #expect(probe.steps == [Self.closeReturnedStep])
        await Self.expectClosed(fixture.session)
        await fixture.end()
    }

    // MARK: - The work of another session

    /// A tool of a fork is the work of the fork, not of its parent. So a
    /// close of the parent from that tool is a close from outside the
    /// parent: it waits until the parent is closed.
    ///
    /// The parent holds a background run that ends only after the test opens
    /// its gate, and the test opens it only after the close cancelled the
    /// run. The production change that makes this test fail: a close that
    /// returns early for the work of any session. The tool then records that
    /// close returned before the run body of the parent ended.
    @Test("a tool of a fork that calls close() of its parent returns only after the parent is closed")
    @MainActor
    func aForkToolThatClosesTheParentWaitsForTheParent() async throws {
        let probe = CloseProbe()
        let fixture = try await Self.makeFixture(probe: probe, route: .direct, mount: nil)
        let parent = try fixture.sessionActor()
        await probe.mayStartClose.open()
        await probe.mayReturn.open()
        let hold = try await Self.startHeldRun(on: parent, recordingTo: probe)
        let child = try await parent.fork(workingDirectory: nil)

        // The fork runs on its own: no tool call of the parent waits for it.
        let answering = Task { try await child.respond(to: Self.prompt) }
        try await hold.sawCancel.wait()
        await hold.unwind.open()
        let answer = try await answering.value

        #expect(answer == Self.toolOutput)
        #expect(probe.steps == [Self.parentRunEndedStep, Self.closeReturnedStep])
        await Self.expectClosed(parent)
        await child.close()
        await fixture.end()
    }

    /// A run body that waits for its cancel, and then holds until the test
    /// lets it end.
    struct HeldRun {
        /// Sent when the run body saw its cancel.
        let sawCancel = AwaitedEvent()

        /// The gate that the run body waits on after its cancel. A cancel
        /// does not end this wait.
        let unwind = RunLatch()
    }

    /// Starts one background run on `session` that waits for its cancel,
    /// then holds until the test opens its gate, and then records
    /// ``parentRunEndedStep`` in `probe`.
    ///
    /// - Parameters:
    ///   - session: The session of the run.
    ///   - probe: The probe that gets the step.
    /// - Returns: The signal and the gate of the run.
    /// - Throws: Nothing now; the wait for the start of the body throws
    ///   only when the test task is cancelled.
    private static func startHeldRun(
        on session: RoutedSessionActor, recordingTo probe: CloseProbe
    ) async throws -> HeldRun {
        let hold = HeldRun()
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AwaitedEvent()
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await SessionDrainTests.waitForCancel()
            hold.sawCancel.signal()
            await hold.unwind.waitUntilOpen()
            probe.record(Self.parentRunEndedStep)
            return OperationEvent(
                tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "",
                outcome: .cancelled)
        }
        try await bodyStarted.wait()
        return hold
    }
}
