import Foundation
import FoundationModels
import Synchronization
import Testing

@_spi(Testing) @testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the stop of all work of a session: the signal
/// ``RoutedSession/cancelAll()``, and the end of a session,
/// ``RoutedSession/close()``.
///
/// ``RoutedSession/cancelAll()`` does not wait for the work that it stops:
/// the stopped answer ends at once for its readers, and the model call and
/// the run bodies unwind later. ``RoutedSession/close()`` runs the same stop,
/// and returns only when no work of the session runs: the model call of the
/// running answer ended, the body of each background run ended, and the mail
/// of a run that settled started no answer.
///
/// The stubs of ``AnswerCancellationTests`` stand in for the model. A model
/// call that takes some turns to unwind after its cancel stands in for a
/// generation that stops at its next token. The tests read the order of the
/// steps, not a clock.
@Suite("The stop of all work of a session: cancelAll() does not wait, and close() returns only when no work runs")
struct SessionDrainTests {
    /// The ways to stop all work of a session.
    enum StopRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// ``RoutedSession/cancelAll()``, then a wait for its terminal event
        /// ``SessionEvent/signalDone(_:)``. The signal does not wait for the
        /// work that it stops.
        case cancelAll

        /// ``RoutedSession/close()``, which stops all work and waits until it
        /// ended.
        case close

        var testDescription: String {
            switch self {
            case .cancelAll: "cancelAll()"
            case .close: "close()"
            }
        }

        /// Stops all work of `session` by this route.
        ///
        /// - Parameter session: The session to stop.
        /// - Throws: When the wait for the end of the signal fails.
        func run(on session: any RoutedSession) async throws {
            switch self {
            case .cancelAll:
                try await AnswerCancellationTests.expectSignalEnds(session.cancelAll(), on: session)
            case .close:
                await session.close()
            }
        }
    }

    /// The turns that a stopped model call or a stopped run body takes to
    /// unwind after it saw its cancel.
    private static let unwindTurns = 100

    /// The steps of a test, in the order they occurred.
    private final class Steps: Sendable {
        /// The steps.
        private let stored = Mutex<[String]>([])

        /// The steps, in order.
        var values: [String] { stored.withLock { $0 } }

        /// Records `step`.
        ///
        /// - Parameter step: The step.
        func append(_ step: String) {
            stored.withLock { $0.append(step) }
        }
    }

    /// Waits until the calling task is cancelled, and then takes
    /// ``unwindTurns`` turns.
    private static func waitForCancelAndUnwind() async {
        let cancelled = AsyncSemaphore(value: 0)
        await withTaskCancellationHandler {
            await cancelled.wait()
        } onCancel: {
            cancelled.signal()
        }
        for _ in 0..<unwindTurns {
            await Task.yield()
        }
    }

    // MARK: - The running answer

    @Test("close() returns only after the model call of the running answer ended")
    @MainActor
    func closeWaitsForTheRunningModelCall() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let steps = Steps()
        let insideModelCall = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { _ in
            insideModelCall.signal()
            await Self.waitForCancelAndUnwind()
            steps.append("model call ended")
            throw CancellationError()
        }

        let answer = Task { try await session.respond(to: "long work") }
        await insideModelCall.wait()

        await session.close()
        steps.append("closed")

        #expect(steps.values == ["model call ended", "closed"])
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
    }

    @Test(
        "cancelAll() ends the running answer at once, and does not wait for a model call that does not see its cancel"
    )
    @MainActor
    func cancelAllDoesNotWaitForTheRunningModelCall() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let steps = Steps()
        let insideModelCall = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        // A model call that does not see its cancel until the test releases it.
        fixture.hook.midAnswer = { _ in
            insideModelCall.signal()
            await release.wait()
            steps.append("model call ended")
        }

        let answer = Task { try await session.respond(to: "stubborn work") }
        await insideModelCall.wait()

        // The signal ends while the model call still holds: the caller gets
        // the end of the answer at once.
        try await StopRoute.cancelAll.run(on: session)
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
        #expect(steps.values.isEmpty)

        // The work ends when the model call ends. The pump then ends.
        release.signal()
        #expect(await session.isIdleOnceThePumpEnds())
        #expect(steps.values == ["model call ended"])
    }

    @Test("a session that cancelAll() stopped answers the next message")
    @MainActor
    func stoppedSessionAnswersAgain() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        try await StopRoute.cancelAll.run(on: session)
        try await StopRoute.cancelAll.run(on: session)

        #expect(
            await AnswerCancellationTests.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    // MARK: - Background runs

    @Test("close() returns only after the body of each background run ended")
    @MainActor
    func closeWaitsForTheBodyOfEachRun() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        let steps = Steps()
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await Self.waitForCancelAndUnwind()
            steps.append("run body ended")
            return OperationEvent(
                tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "",
                outcome: .cancelled)
        }
        await bodyStarted.wait()

        await session.close()
        steps.append("closed")

        #expect(steps.values == ["run body ended", "closed"])
        #expect(await session.runPlane.backgroundRuns().isEmpty)
    }

    @Test("cancelAll() cancels each background run, and the session becomes idle when the run ended")
    @MainActor
    func cancelAllCancelsEachRun() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        let steps = Steps()
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await Self.waitForCancelAndUnwind()
            steps.append("run body ended")
            return OperationEvent(
                tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "",
                outcome: .cancelled)
        }
        await bodyStarted.wait()

        // The signal does not wait for the sweep of the runs, so the test
        // waits for the session to become idle.
        try await StopRoute.cancelAll.run(on: session)
        #expect(await session.awaitIdle())

        #expect(await session.runPlane.backgroundRuns().isEmpty)
        await session.close()
        #expect(steps.values == ["run body ended"])
    }

    @Test(
        "a run that settles after the stop of all work makes no mail, and starts no answer",
        arguments: StopRoute.allCases)
    @MainActor
    func mailAfterTheStopStartsNoAnswer(route: StopRoute) async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        let terminalPosted = AwaitedEvent()
        let outbox = session.outbox
        let terminal = OperationEvent(
            tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "late",
            outcome: .succeeded)
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await Self.waitForCancelAndUnwind()
            // The run posts its own terminal after the sweep, as a run that
            // finishes its work after a cancel does.
            await outbox.post(event: terminal)
            terminalPosted.signal()
            return terminal
        }
        await bodyStarted.wait()

        try await route.run(on: session)
        // cancelAll() does not wait for the run body, so the test waits for
        // the post of the terminal. close() already waited for it.
        try await terminalPosted.wait()

        #expect(await session.becomesIdle())
        #expect(await fixture.observer.entered.isEmpty)
        // A stopped run makes no more mail: the terminal that it posts after
        // the stop is not queued.
        #expect(await outbox.pending().events.isEmpty)
        await session.close()
    }
}
