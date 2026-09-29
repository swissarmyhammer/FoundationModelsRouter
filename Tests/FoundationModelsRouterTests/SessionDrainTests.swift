import Foundation
import FoundationModels
import Synchronization
import Testing

@_spi(Testing) @testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/drain()`` and the drain that ``RoutedSession/close()``
/// runs: when the call returns, no work of the session runs. The model call
/// of the running answer ended, the body of each background run ended, and
/// the mail of a run that settled started no answer.
///
/// The stubs of ``AnswerCancellationTests`` stand in for the model. A model
/// call that takes some turns to unwind after its cancel stands in for a
/// generation that stops at its next token. The tests read the order of the
/// steps, not a clock. The `.timeLimit` ends a drain that never returns.
@Suite("The drain of a session returns only when no work of the session runs", .timeLimit(.minutes(1)))
struct SessionDrainTests {
    /// The ways to drain a session.
    enum DrainRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// ``RoutedSession/drain()``.
        case drain

        /// ``RoutedSession/close()``, which runs the drain.
        case close

        var testDescription: String {
            switch self {
            case .drain: "drain()"
            case .close: "close()"
            }
        }

        /// Drains `session` by this route.
        ///
        /// - Parameter session: The session to drain.
        /// - Returns: What ``RoutedSession/drain()`` returns, or `true` for
        ///   ``RoutedSession/close()``.
        func run(on session: any RoutedSession) async -> Bool {
            switch self {
            case .drain:
                return await session.drain()
            case .close:
                await session.close()
                return true
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

    @Test("the drain returns only after the model call of the running answer ended", arguments: DrainRoute.allCases)
    @MainActor
    func drainWaitsForTheRunningModelCall(route: DrainRoute) async throws {
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

        #expect(await route.run(on: session))
        steps.append("drained")

        #expect(steps.values == ["model call ended", "drained"])
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
    }

    @Test("a session that was drained answers the next message")
    @MainActor
    func drainedSessionAnswersAgain() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        #expect(await session.drain())
        #expect(await session.drain())

        #expect(
            await AnswerCancellationTests.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("a cancel of the caller ends the wait of drain(), and a later drain() waits for the same work")
    @MainActor
    func cancelledDrainCanBeCalledAgain() async throws {
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

        let firstDrain = Task { await session.drain() }
        firstDrain.cancel()
        #expect(await firstDrain.value == false)
        #expect(steps.values.isEmpty)

        release.signal()
        #expect(await session.drain())
        steps.append("drained")

        #expect(steps.values == ["model call ended", "drained"])
        _ = try? await answer.value
    }

    // MARK: - Background runs

    @Test("the drain returns only after the body of each background run ended", arguments: DrainRoute.allCases)
    @MainActor
    func drainWaitsForTheBodyOfEachRun(route: DrainRoute) async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        let steps = Steps()
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        await session.mailbox.start(
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

        #expect(await route.run(on: session))
        steps.append("drained")

        #expect(steps.values == ["run body ended", "drained"])
        #expect(await session.mailbox.backgroundRuns().isEmpty)
    }

    @Test("the mail of a run that settles during the drain starts no answer, and stays held")
    @MainActor
    func mailDuringTheDrainStartsNoAnswer() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        let outbox = session.outbox
        let terminal = OperationEvent(
            tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "late",
            outcome: .succeeded)
        await session.mailbox.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await Self.waitForCancelAndUnwind()
            // The run posts its own terminal after the sweep, as a run that
            // finishes its work after a cancel does.
            await outbox.post(event: terminal)
            return terminal
        }
        await bodyStarted.wait()

        #expect(await session.drain())

        #expect(await session.isPumpRunning == false)
        #expect(await fixture.observer.entered.isEmpty)
        let pending = await outbox.pending().events
        #expect(pending.map(\.event.correlationID) == [token])
        #expect(pending.allSatisfy { $0.isHeld })
    }
}
