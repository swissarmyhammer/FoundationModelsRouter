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
/// running answer ended, the generation pass of that model call ended, each
/// helper task of that model call ended and keeps the profile no more, the
/// body of each background run ended, and the mail of a run that settled
/// started no answer.
///
/// The stubs of ``AnswerCancellationTests`` stand in for the model. A model
/// call that holds after its cancel until the test opens a gate stands in
/// for a generation that stops at its next token. The tests read the order
/// of the steps, not a clock.
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

    /// A model call or a run body that waits for its cancel, and then holds
    /// until the test lets it unwind. The test opens ``unwind`` at the point
    /// that it chooses, so the end of the work has a fixed place in the
    /// order of the steps.
    private final class CancelledHold: Sendable {
        /// Sent when the work saw its cancel.
        let sawCancel = AwaitedEvent()

        /// The gate that the work waits on after its cancel. A cancel does
        /// not end this wait.
        let unwind = RunLatch()

        /// Waits until the calling task is cancelled, sends ``sawCancel``,
        /// and then waits until ``unwind`` opens.
        func waitForCancelAndUnwind() async {
            await SessionDrainTests.waitForCancel()
            sawCancel.signal()
            await unwind.waitUntilOpen()
        }
    }

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

    /// One use of a model handle. The generation of a model call keeps it
    /// while its pass runs. A weak reference to it tells the test when the
    /// generation let the handle go.
    private final class ModelHandleLease: Sendable {
        /// The model handle. It keeps the holds of its profile in the pool.
        let handle: RoutedLLM

        /// Makes a lease of `handle`.
        ///
        /// - Parameter handle: The model handle.
        init(handle: RoutedLLM) {
            self.handle = handle
        }
    }

    /// A generation that runs on a task of its own, as the framework runs the
    /// pass of a model call. The framework resumes a cancelled model call
    /// before that pass ends.
    ///
    /// The generation reports its pass to the pass observer of the session,
    /// keeps a model handle while the pass runs, and waits on ``gate``. A
    /// cancel does not end that wait. When the gate opens, the generation lets
    /// the handle go, records the step "generation ended", and ends its pass.
    private final class DetachedGeneration: Sendable {
        /// Sent when the pass started and the generation keeps the handle.
        let started = AwaitedEvent()

        /// The gate that the generation waits on. A cancel does not end the
        /// wait.
        let gate = RunLatch()

        /// The handle that the generation keeps while its pass runs, or `nil`
        /// after the generation let it go.
        private let lease: Mutex<ModelHandleLease?>

        /// The steps of the test.
        private let steps: Steps

        /// The task of the generation, after ``start(reportingTo:)``.
        private let task = Mutex<Task<Void, Never>?>(nil)

        /// Makes a generation that keeps `lease` while its pass runs.
        ///
        /// - Parameters:
        ///   - lease: The model handle that the pass keeps.
        ///   - steps: The steps of the test.
        init(keeping lease: ModelHandleLease, steps: Steps) {
            self.lease = Mutex(lease)
            self.steps = steps
        }

        /// The handle that the generation keeps now, or `nil`.
        var keptLease: ModelHandleLease? {
            lease.withLock { $0 }
        }

        /// Starts the generation on a detached task, as the framework starts
        /// the pass of a model call.
        ///
        /// - Parameter observer: The pass observer of the session.
        func start(reportingTo observer: GenerationPassObserver) {
            let generation = Task.detached {
                observer.passStarted()
                self.started.signal()
                await self.gate.waitUntilOpen()
                self.lease.withLock { $0 = nil }
                self.steps.append("generation ended")
                observer.passEnded()
            }
            task.withLock { $0 = generation }
        }

        /// Waits until the task of the generation ended.
        func ended() async {
            await task.withLock { $0 }?.value
        }
    }

    /// A run clock that never reaches a deadline by itself. Each sleep waits
    /// for its cancel, and then holds until the test opens ``release``. It
    /// stands in for a stall watchdog that ends late after its cancel.
    private final class HeldSleepClock: RunClock {
        /// The one instant of the clock. The clock does not move.
        private let start = ContinuousClock.now

        /// The gate that each cancelled sleep waits on. A cancel does not
        /// end this wait.
        let release = RunLatch()

        var now: ContinuousClock.Instant {
            start
        }

        /// Waits until the calling task is cancelled, then waits until
        /// ``release`` opens, and then throws `CancellationError`.
        ///
        /// - Parameter deadline: Not read: the clock never reaches it.
        /// - Throws: `CancellationError`, always.
        func sleep(until deadline: ContinuousClock.Instant) async throws {
            await SessionDrainTests.waitForCancel()
            await release.waitUntilOpen()
            throw CancellationError()
        }
    }

    /// The work of a signal of a test. It reports its start, and then holds
    /// until the test opens ``gate``. A cancel does not end the hold.
    private final class HeldSignalWork: Sendable {
        /// Sent when the work started.
        let started = AwaitedEvent()

        /// The gate that the work waits on. A cancel does not end this wait.
        let gate = RunLatch()

        /// Sends ``started``, and then waits until ``gate`` opens.
        func hold() async {
            started.signal()
            await gate.waitUntilOpen()
        }
    }

    /// The prompt of the mail that a test sends just before close.
    private static let mailBeforeClosePrompt = "a message that close cancels"

    /// The stall report interval of the session of a test that holds the
    /// stall watchdog. A ``HeldSleepClock`` never reaches it, so the watchdog
    /// sleeps until its cancel.
    private static let heldWatchdogInterval: Duration = .seconds(1)

    /// Makes a session over the hooked stub model whose profile no other
    /// reference keeps: the fixture, its router and its profile are gone when
    /// this function returns. Only the session, its work and its tasks keep
    /// the profile then. The hook keeps no reference to the profile.
    ///
    /// - Parameters:
    ///   - cacheDir: The cache and recording root of the router.
    ///   - runClock: The clock of the run plane and of the stall watch, or
    ///     `nil` for the real time.
    /// - Returns: The session, and the hook whose closure each model call of
    ///   the session runs.
    /// - Throws: When the fixture cannot resolve its profile.
    private static func makeSessionThatAloneKeepsItsProfile(
        cacheDir: URL,
        runClock: (any RunClock)? = nil
    ) async throws -> (session: RoutedSessionActor, hook: AnswerHook) {
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: cacheDir, runClock: runClock)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        return (session, fixture.hook)
    }

    /// Waits until the calling task is cancelled. Only a cancel ends the
    /// wait.
    static func waitForCancel() async {
        let cancelled = AsyncSemaphore(value: 0)
        await withTaskCancellationHandler {
            await cancelled.wait()
        } onCancel: {
            cancelled.signal()
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
        let hold = CancelledHold()
        defer {
            await hold.unwind.open()
            await session.close()
        }
        fixture.hook.midAnswer = { _ in
            insideModelCall.signal()
            await hold.waitForCancelAndUnwind()
            steps.append("model call ended")
            throw CancellationError()
        }

        let answer = Task { try await session.respond(to: "long work") }
        // Rule T1: the wait also ends when the answer ended. The answer ends
        // only after the test stops it below.
        try await RecordedWaitResult.wait(
            for: { try await insideModelCall.waitUnlessCancelled() }, endingOnEndOf: answer)

        // The close cancels the model call, and then waits for its end. The
        // model call ends only after the test opens the gate.
        let closing = Task {
            await session.close()
            steps.append("closed")
        }
        try await hold.sawCancel.wait()
        await hold.unwind.open()
        await closing.value

        #expect(steps.values == ["model call ended", "closed"])
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
    }

    /// The framework resumes a cancelled model call before the pass of its
    /// generation ends, and that pass keeps the model handles of the profile.
    /// The model call of this test returns at its cancel, as the framework
    /// does, and its generation runs on until the test opens the gate.
    ///
    /// The test opens the gate only when close waits for the open pass. When
    /// close does not wait, it returns first, and the steps show "closed"
    /// alone.
    ///
    /// After close returned and the test dropped the session, no reference
    /// keeps the profile: the fixture is gone, and the lease of the generation
    /// keeps the model handle only, which keeps its profile weakly.
    @Test("close() returns only after the generation of the stopped model call ended and let its model handle go")
    @MainActor
    func closeWaitsForTheGenerationOfTheStoppedModelCall() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session: RoutedSessionActor?
        let hook: AnswerHook
        (session, hook) = try await Self.makeSessionThatAloneKeepsItsProfile(cacheDir: dir)
        weak let profile = session?.profile
        let observer = try #require(session?.generationPassObserver)
        let steps = Steps()
        let generation = DetachedGeneration(
            keeping: ModelHandleLease(handle: try #require(session?.profile.standard)), steps: steps)
        weak let lease = generation.keptLease
        let insideModelCall = AsyncSemaphore(value: 0)
        // The close waits for the pass, so the gate opens first.
        defer {
            await generation.gate.open()
            await session?.close()
            await generation.ended()
        }
        hook.midAnswer = { _ in
            generation.start(reportingTo: observer)
            insideModelCall.signal()
            await Self.waitForCancel()
            throw CancellationError()
        }

        let answer = Task { [session] in try await session?.respond(to: "long work") }
        // Rule T1: the wait also ends when the answer ended. The answer ends
        // only after the test stops it below.
        try await RecordedWaitResult.wait(
            for: { try await insideModelCall.waitUnlessCancelled() }, endingOnEndOf: answer)
        try await generation.started.wait()

        let closing = Task { [session] in
            await session?.close()
            steps.append("closed")
        }
        let passEndWaiters = try #require(observer.passEnds.waiterChanges)
        let gateOpener = Task {
            try await passEndWaiters.wait(until: { observer.passEnds.waiterCount > 0 })
            await generation.gate.open()
        }
        defer { gateOpener.cancel() }
        await closing.value

        #expect(steps.values == ["generation ended", "closed"])
        #expect(lease == nil)
        #expect(observer.openPassCount == 0)
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
        session = nil
        #expect(profile == nil)
    }

    /// Each model call starts helper tasks: the stall watchdog and the reader
    /// of the pass reports. Each of them keeps the session, and thus its
    /// profile. The call cancels them and does not wait. The stall watchdog
    /// of this test sleeps on a ``HeldSleepClock``, so after its cancel it
    /// holds until the test opens the gate of the clock.
    ///
    /// The test opens the gate only when close waits for a helper task. When
    /// close does not wait, it returns while the watchdog holds, and the
    /// watchdog still keeps the profile after the test dropped the session.
    @Test("after close() returns, no task of the session keeps its profile")
    @MainActor
    func closeLeavesNoTaskThatKeepsTheProfile() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = HeldSleepClock()
        var session: RoutedSessionActor?
        let hook: AnswerHook
        (session, hook) = try await Self.makeSessionThatAloneKeepsItsProfile(cacheDir: dir, runClock: clock)
        weak let profile = session?.profile
        // The close waits for the watchdog, so the gate of the clock opens first.
        defer {
            await clock.release.open()
            await session?.close()
        }
        let helperTasks = try #require(session?.helperTasks)
        let insideModelCall = AsyncSemaphore(value: 0)
        hook.midAnswer = { _ in
            insideModelCall.signal()
            await Self.waitForCancel()
            throw CancellationError()
        }
        await session?.setGenerationStallReportInterval(Self.heldWatchdogInterval)

        let answer = Task { [session] in try await session?.respond(to: "long work") }
        // Rule T1: the wait also ends when the answer ended. The answer ends
        // only after the test stops it below.
        try await RecordedWaitResult.wait(
            for: { try await insideModelCall.waitUnlessCancelled() }, endingOnEndOf: answer)

        let taskEndWaiters = try #require(helperTasks.taskEnds.waiterChanges)
        let releaseOpener = Task {
            try await taskEndWaiters.wait(until: { helperTasks.taskEnds.waiterCount > 0 })
            await clock.release.open()
        }
        defer { releaseOpener.cancel() }
        await session?.close()
        await #expect(throws: CancellationError.self) {
            try await answer.value
        }
        session = nil

        #expect(profile == nil)
        #expect(helperTasks.liveTaskCount == 0)
    }

    /// A compaction resumes the mail queue and wakes the pump only when no
    /// signal waits or runs. In this test a held signal comes before the
    /// requested compaction, and a second held signal comes after it. So the
    /// compaction runs after the first signal, and its wake of the pump waits
    /// for the end of the second signal. The task of each signal keeps the
    /// session, and thus its profile.
    ///
    /// The test opens the gate of the second signal only when close waits for
    /// the signal tasks. When close does not wait, it returns while that
    /// signal holds, and its task still keeps the profile after the test
    /// dropped the session.
    @Test("close() returns only after the task of each signal and the wake of the pump after a compaction ended")
    @MainActor
    func closeWaitsForTheSignalTasksAndTheWakeAfterACompaction() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session: RoutedSessionActor?
        (session, _) = try await Self.makeSessionThatAloneKeepsItsProfile(cacheDir: dir)
        weak let profile = session?.profile
        let signals = try #require(session?.signals)
        let before = HeldSignalWork()
        let after = HeldSignalWork()
        // The close waits for the signal tasks, so their gates open first.
        defer {
            await before.gate.open()
            await after.gate.open()
            await session?.close()
        }
        session?.submitSignal(SignalID(), { _ in await before.hold() })
        session?.compact()
        session?.submitSignal(SignalID(), { _ in await after.hold() })

        try await before.started.wait()
        await before.gate.open()
        try await after.started.wait()

        let taskEndWaiters = try #require(signals.taskEnds.waiterChanges)
        let gateOpener = Task {
            try await taskEndWaiters.wait(until: { signals.taskEnds.waiterCount > 0 })
            await after.gate.open()
        }
        defer { gateOpener.cancel() }
        await session?.close()
        #expect(await session?.isPumpRunning == false)
        session = nil

        #expect(profile == nil)
    }

    /// A mail wakes the pump from a task of its own after its put, and that
    /// task keeps the session until it ran. The test sends the mail and
    /// starts close in the isolation of the session, with no suspension point
    /// between them. So that task can run only after close began, and it
    /// cannot end before close began.
    @Test("close() returns only after the task that wakes the pump for a mail ended, and that task starts no pump")
    @MainActor
    func closeWaitsForTheWakeOfAMail() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var session: RoutedSessionActor?
        (session, _) = try await Self.makeSessionThatAloneKeepsItsProfile(cacheDir: dir)
        defer { await session?.close() }
        weak let profile = session?.profile
        let helperTasks = try #require(session?.helperTasks)

        let liveTasksAfterTheMail = try await Self.sendAndClose(try #require(session))

        #expect(liveTasksAfterTheMail == 1)
        #expect(helperTasks.liveTaskCount == 0)
        #expect(await session?.isPumpRunning == false)
        session = nil
        #expect(profile == nil)
    }

    /// After close began, no pump starts: a wake that comes from a task that
    /// close did not stop in time, or from a signal call after close, finds
    /// no work to do.
    @Test("after close(), a wake of the pump starts no pump")
    @MainActor
    func wakeAfterCloseStartsNoPump() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        let session = try #require(fixture.model.makeSession() as? RoutedSessionActor)
        await session.close()

        #expect(await Self.wakePumpAndReadIt(on: session) == false)
    }

    /// Sends one mail to `session`, and then closes it, in the isolation of
    /// the session. No suspension point comes between the send and the start
    /// of close, so no task that needs the session runs between them.
    ///
    /// - Parameter session: The session.
    /// - Returns: The count of the live helper tasks of the session right
    ///   after the send.
    /// - Throws: The refusal of the mail.
    private static func sendAndClose(_ session: isolated RoutedSessionActor) async throws -> Int {
        try session.send(mailBeforeClosePrompt)
        let liveTasks = session.helperTasks.liveTaskCount
        await session.close()
        return liveTasks
    }

    /// Wakes the pump of `session`, and reads at once whether a pump runs, in
    /// the isolation of the session.
    ///
    /// - Parameter session: The session.
    /// - Returns: `true` when the wake started a pump.
    private static func wakePumpAndReadIt(on session: isolated RoutedSessionActor) -> Bool {
        session.wakePump()
        return session.isPumpRunning
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
        // Rule T1: the wait also ends when the answer ended. The answer ends
        // only after the test stops it below.
        try await RecordedWaitResult.wait(
            for: { try await insideModelCall.waitUnlessCancelled() }, endingOnEndOf: answer)

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
        let hold = CancelledHold()
        defer {
            await hold.unwind.open()
            await session.close()
        }
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await hold.waitForCancelAndUnwind()
            steps.append("run body ended")
            return OperationEvent(
                tool: "fake", op: "run task", correlationID: token, kind: .completed, detail: "",
                outcome: .cancelled)
        }
        await bodyStarted.wait()

        // The close cancels the run, and then waits for the end of its body.
        // The body ends only after the test opens the gate.
        let closing = Task {
            await session.close()
            steps.append("closed")
        }
        try await hold.sawCancel.wait()
        await hold.unwind.open()
        await closing.value

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
        defer { await session.close() }
        let steps = Steps()
        let token = RunPlane.makeCompletionToken()
        let bodyStarted = AsyncSemaphore(value: 0)
        await session.runPlane.start(
            tool: "fake", op: "run task", kind: .swiftTask, completionToken: token, canceler: nil
        ) {
            bodyStarted.signal()
            await Self.waitForCancel()
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
        defer { await session.close() }
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
            await Self.waitForCancel()
            // The run posts its own terminal after the sweep, as a run that
            // finishes its work after a cancel does. The stop marks the run
            // as one that makes no mail before the sweep cancels the run.
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
    }
}
