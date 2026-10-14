import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the stop of the answer that already **runs**: the public
/// ``RoutedSession/cancelAll()``, and the test-only `stopRunningWork()`,
/// which only stops the running work. A cancel of one mail (``RoutedSession/cancel(_:)``)
/// acts only on queued mail, and a cancel of the caller task of
/// ``RoutedSession/respond(to:)`` or ``RoutedSession/streamEvents(to:)``
/// only ends the wait of that caller. Neither stops a running answer.
///
/// The chain this closes is `ACP session/cancel` -> Router -> MCP
/// `notifications/cancelled`: `FoundationModelsMCP` changes Swift task
/// cancellation into the protocol-level notification. Router must cancel the
/// `Task` that owns the model call a tool runs inside. These tests prove that
/// the stop reaches *inside* the model call, that the session records a
/// stopped submission as it records each other failed submission, that the
/// pump of the session continues after the stop, that the no-op cases are
/// no-ops, and that a cancel of a caller task does not stop the answer.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, exactly as in
/// ``HumanWaitGateTests``. Determinism comes from ``AsyncSemaphore``
/// observability rather than from sleeps.
///
/// The moment that each test here needs — the stop reaches the tool call
/// inside the model call — is an ``AwaitedEvent`` that the tool itself
/// signals. It is not a value that the test reads until a wall clock ends
/// (task ^bqj719z). A loaded machine makes such a test slower, and never red.
///
/// The suite is in five files, one for each part: this file holds the suite
/// and the tests of the regression, the recording, the stranded work and the
/// outbox rule. `AnswerCancellationStubs.swift` holds the stubs,
/// `AnswerCancellationFixtures.swift` the fixtures,
/// `AnswerCancellationEntryPointTests.swift` the tests of the entry points,
/// the no-op cases and the queue-side cancel, and
/// `AnswerCancellationCompactionTests.swift` the tests of a stop during a
/// compaction.
@Suite(
    "The cancel of a running answer reaches the model call, and the tools inside it")
struct AnswerCancellationTests {
    /// The routes that can stop running work of the pump, so a test can assert
    /// the same behavior of each route and does not copy itself for each route.
    enum CancellationRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// The stop of the running work only (`stopRunningWork()`). It cancels
        /// no queued mail, sends no early terminal event, and does not wait.
        case stopRunningWork

        /// ``RoutedSession/cancelAll()``: the public stop of all work. It
        /// also cancels each queued mail and sweeps the background runs. The
        /// stopped answer gets its terminal event at once. The signal does
        /// not wait for the pump.
        case cancelAll

        /// The routes that stop a running answer. A cancel of a caller task
        /// stops no answer, and no route stops a running compaction: only
        /// ``RoutedSession/close()`` cancels a compaction.
        static let answerRoutes: [CancellationRoute] = [.stopRunningWork, .cancelAll]

        /// The name of the route in the test report.
        var testDescription: String {
            switch self {
            case .stopRunningWork: "stopRunningWork()"
            case .cancelAll: "cancelAll()"
            }
        }
    }

    /// The stop that ``requestStop(of:by:)`` sent with
    /// ``RoutedSession/cancelAll()``: the session and the id of the signal.
    struct StopRequest: Sendable {
        /// The session that got the signal.
        let session: any RoutedSession

        /// The id of the signal.
        let signal: SignalID
    }

    /// Stops the running work of `session` by `route`.
    ///
    /// ``RoutedSession/cancelAll()`` returns at once and does not wait for
    /// the pump. ``expectStopEnds(_:)`` waits for the end of the signal and
    /// for the end of the pump.
    ///
    /// - Parameters:
    ///   - session: The session whose pump runs the work.
    ///   - route: The route of the stop.
    /// - Returns: The stop request for ``CancellationRoute/cancelAll``, and
    ///   `nil` for ``CancellationRoute/stopRunningWork``.
    static func requestStop(of session: any RoutedSession, by route: CancellationRoute) async -> StopRequest? {
        switch route {
        case .stopRunningWork:
            #expect(await session.stopRunningWork())
            return nil
        case .cancelAll:
            return StopRequest(session: session, signal: session.cancelAll())
        }
    }

    /// Expects that the signal of `stop` ends with its terminal event
    /// ``SessionEvent/signalDone(_:)``, and waits for the end of the pump of
    /// the session. Does nothing for `nil`.
    ///
    /// Call it only after the stopped work unwound or can unwind: then the
    /// pump ends soon. The wait ends when the pump ends.
    ///
    /// - Parameter stop: The stop request, or `nil`.
    /// - Throws: When the wait for the signal or for the pump fails.
    static func expectStopEnds(_ stop: StopRequest?) async throws {
        if let stop {
            try await expectSignalEnds(stop.signal, on: stop.session)
            #expect(await stop.session.isIdleOnceThePumpEnds())
        }
    }

    /// Waits for the end of the signal `signal`, and expects that its
    /// terminal event is ``SessionEvent/signalDone(_:)``. The effect of a
    /// signal is not synchronous, so a test calls this before it checks the
    /// effect.
    ///
    /// - Parameters:
    ///   - signal: The id of the signal.
    ///   - session: The session that got the signal.
    /// - Throws: When the wait for the terminal event fails.
    static func expectSignalEnds(_ signal: SignalID, on session: any RoutedSession) async throws {
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
    }

    /// Waits until the work that the pump of `session` runs has a stop
    /// requested (``RoutedSessionActor/cancelRequestedWorkId``).
    ///
    /// Each stop of the running work
    /// (``RoutedSessionActor/requestCancelOfRunningWork()``) sets the id and
    /// then signals ``RoutedSessionActor/stateChanges``. The end of the work
    /// clears the id. So a set id tells that the running work has a stop
    /// requested.
    ///
    /// The wait does not read ``RoutedSessionActor/isWorkCancelled``: that
    /// read also gives `true` when the task of the reader is cancelled.
    ///
    /// Use it only when the work cannot end before the test lets it end:
    /// else the work can end before the read, and the wait never ends. The
    /// wait ends when the stop is requested.
    ///
    /// - Parameter session: The session whose pump runs the work.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   before the stop was requested.
    static func awaitStopRequested(on session: any RoutedSession) async throws {
        let actor = try #require(session as? RoutedSessionActor)
        try await session.stateChanges.wait(until: { await actor.cancelRequestedWorkId != nil })
    }

    /// Failures a test's own stand-in tool raises — to mark a path that must never
    /// be taken, or to stand in for a fault the model itself would raise.
    enum ProbeError: Error, Equatable {
        /// The overflow retry re-entered the model even though the answer had
        /// already been cancelled.
        case modelReenteredAfterCancellation

        /// A summarizer call failed for a reason of its own, with nothing about it
        /// cancellation-shaped.
        case summarizerFailed
    }

    // MARK: - The regression: a stop must reach a running tool call

    @Test(
        "a stop cancels the model call of the running answer, and the tool inside it sees CancellationError",
        arguments: CancellationRoute.answerRoutes)
    @MainActor
    func cancellingARunningAnswerReachesTheToolCall(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        let stop = await Self.requestStop(of: session, by: route)

        // The important result: the tool call *inside* the model call sees the
        // cancel, and then the answer unwinds with it.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)
        try await Self.expectStopEnds(stop)
    }

    @Test("a cancel of the caller task of respond ends the wait of the caller, and the answer goes on to its end")
    @MainActor
    func cancellingTheCallersOwnTaskLeavesTheAnswerToItsEnd() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The tool does not stop on a cancel. It waits for the test, so the
        // answer can end only after the test releases the tool.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("caller-cancels") else { return }
            insideTool.signal()
            await release.wait()
        }

        let feed = await session.streamSessionEvents()
        let answerTask = Task { try await session.respond(to: "caller-cancels") }
        await insideTool.wait()

        // The mail of the caller is in the open answer. The cancel of the
        // caller task ends the wait of the caller, and it does not stop the
        // answer: the tool still holds the answer when the caller ends.
        answerTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.toolSawCancellation == false)

        // The answer goes on to its end, and the session records the full
        // submission.
        release.signal()
        let events = await feed.eventsToTheFirstAnswerEnd()
        #expect(events.answers.map(\.reply) == ["ok-caller-cancels"])
        #expect(events.answerFailures.isEmpty)
        #expect(await fixture.recorder.events.withoutMailRecords.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.withoutMailRecords.last?.text == "ok-caller-cancels")
        #expect(await session.becomesIdle())
    }

    // MARK: - Recording

    @Test("a cancelled submission is recorded exactly like any other failed submission, and the session keeps working")
    @MainActor
    func cancelledSubmissionLeavesAConsistentTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Whatever the SDK durably appended before the cancellation landed (the
        // `.prompt` entry of the submission), plus exactly one close — the
        // synthetic bodyless `.response` every failed submission gets, never two
        // and never none.
        let cancelledSubmissionEvents = await fixture.recorder.events.withoutMailRecords
        #expect(cancelledSubmissionEvents.map(\.kind) == [.session, .prompt, .response])
        let close = try #require(cancelledSubmissionEvents.last)
        #expect(close.text == nil)
        #expect(close.ms != nil)

        // Nothing was left half-written: an ordinary answer on the same session
        // records its own whole prompt/response pair straight after.
        // `followUpAnswerCompletes` waits for that answer, and then checks
        // that its model call ended.
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        let afterEvents = await fixture.recorder.events.withoutMailRecords
        #expect(afterEvents.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(afterEvents.last?.text == "ok-after")
    }

    // MARK: - Nothing stranded

    @Test("cancelling an answer whose tool body waits for a person leaves the session idle and blocks no other session")
    @MainActor
    func cancellingAnAnswerThatWaitsForAPersonLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The tool body of the answer waits for a person, directly, when the
        // cancellation arrives: the interaction between the cancel of a running
        // answer and a wait inside a tool body. The session has no wrapper for
        // such a wait, so the wait holds nothing of its own.
        let insideWait = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, prompt: "cancel-in-wait", insideTool: insideWait)

        let answerTask = Task { try await sessionA.respond(to: "cancel-in-wait") }
        await insideWait.wait()
        #expect(await sessionA.isPumpRunning)

        #expect(await sessionA.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The answer ended, and nothing of it waits.
        #expect(await sessionA.becomesIdle())

        // The behavioral proof: another session over the same model still
        // generates, and so does the cancelled one.
        #expect(await Self.followUpAnswerCompletes(on: sessionB, observer: fixture.observer, prompt: "other-session"))
        #expect(await Self.followUpAnswerCompletes(on: sessionA, observer: fixture.observer))
        #expect(await sessionA.becomesIdle())
    }

    // MARK: - The outbox rule

    @Test("a cancelled submission that durably delivered its drained events records them rather than re-queueing them")
    @MainActor
    func cancelledSubmissionKeepsDeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends the `.prompt` entry of the submission before the tool runs,
        // so the composed preamble carrying the drained event really did reach
        // the model before the cancellation landed.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: true)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Delivered, so not re-queued: the drained event rode the recorded
        // prompt of the cancelled submission and is not staged again.
        let pending = await session.outbox.pending()
        #expect(pending.events.isEmpty)
        let promptEvent = try #require(await fixture.recorder.events.first { $0.kind == .prompt })
        #expect(promptEvent.text?.contains("run command") == true)
    }

    @Test("a cancelled submission that delivered nothing re-queues its drained events instead of destroying them")
    @MainActor
    func cancelledSubmissionRequeuesUndeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends nothing before the tool runs, so a cancellation
        // there leaves the submission with no `.prompt` partial for the drained event
        // to attach to — it was never durably delivered.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: false)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.stopRunningWork())
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }
}
