import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/cancel()``: cancelling the answer that already
/// **runs**, as opposed to ``RoutedSession/cancel(message:)``'s withdrawal
/// of a message that waits for a submission.
///
/// The chain this closes is `ACP session/cancel` -> Router -> MCP
/// `notifications/cancelled`: `FoundationModelsMCP` already turns Swift task
/// cancellation into the protocol-level notification, and a client stop already
/// reaches Router — so the only missing link was Router's own ability to cancel
/// the `Task` that owns the model call a tool runs inside. These tests prove
/// cancellation reaches *inside* the model call (the regression the work exists
/// for), that a cancelled submission is recorded exactly like any other failed
/// submission rather than half-written, that the pump of the session survives
/// it, and that the documented no-op cases really are no-ops.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, exactly as in
/// ``HumanWaitGateTests``. Determinism comes from ``AsyncSemaphore``
/// observability rather than from sleeps.
///
/// The moment every test here depends on — a cancellation reaching the tool call
/// running inside the model call — is an ``AwaitedEvent`` the tool itself signals,
/// rather than a reading polled until a wall clock runs out (task ^bqj719z).
///
/// A clock was the wrong measure because the crossing is not quick on every route.
/// ``RoutedSession/cancel()`` cancels the model call directly, so the
/// stop lands in microseconds. A caller cancelling its own stream consumer reaches
/// the tool only once that consumer runs *again*: the consumer's next `next()`
/// terminates the stream, the termination handler cancels the answer behind it, and
/// only then does the stop travel on. That consumer is `@MainActor`, so it runs
/// when the one main actor every `@MainActor` test in the run shares gives it a
/// slot. Measured on ``cancelledProactiveCompactionReportsNoCompaction(route:)``: the
/// wait takes tens of microseconds run alone and under `--no-parallel`, and about
/// two seconds in half of the full parallel runs. That number reads the run, not
/// Router, so a five-second ceiling over it is a coin toss on a busier machine.
///
/// Waited on instead, a slower run makes such a test slower and never red. What
/// ends a wait the cancellation genuinely never reaches — the regression these
/// tests exist to catch — is the `.timeLimit` below: a ceiling on a fault, thirty
/// times the slowest crossing measured, and never a budget for the work.
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
    "The cancel of a running answer reaches the model call, and the tools inside it",
    .timeLimit(.minutes(1)))
struct AnswerCancellationTests {
    /// The two routes that can cancel a running answer, so a test can assert
    /// the same behavior of both instead of duplicating itself per route.
    enum CancellationRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// ``RoutedSession/cancel()`` — Router's own primitive.
        case routerAPI

        /// The caller of the answer cancelling its own enclosing `Task` — the propagation
        /// Router had before it had a primitive of its own.
        case callerTask

        var testDescription: String {
            switch self {
            case .routerAPI: "cancel()"
            case .callerTask: "the caller's own Task"
            }
        }
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

    @Test("cancel() cancels the model call of the running answer, and the tool running inside it sees CancellationError")
    @MainActor
    func cancellingARunningAnswerReachesTheToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        #expect(await session.cancel() == .requested)

        // The whole point: the tool call *inside* the model call observes the
        // cancellation, and the answer then unwinds with it.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)
    }

    @Test("cancelling the caller's own Task still reaches the tool call, exactly as before")
    @MainActor
    func cancellingTheCallersOwnTaskStillReachesTheToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "caller-cancels", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "caller-cancels") }
        await insideTool.wait()

        // Router runs the model call in a task of its own so it can cancel it
        // from outside; that must not cost the caller the propagation plan.md
        // always promised from cancelling its own enclosing `Task`.
        answerTask.cancel()

        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // Recorded the same way as a submission cancelled through `cancel()`,
        // even though this cancellation unwinds the task the recording itself runs
        // in: nothing on the recording path observes cancellation, so a
        // caller-cancelled submission is no more half-written than any other failed one.
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == nil)
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
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Whatever the SDK durably appended before the cancellation landed (the
        // `.prompt` entry of the submission), plus exactly one close — the
        // synthetic bodyless `.response` every failed submission gets, never two
        // and never none.
        let cancelledSubmissionEvents = await fixture.recorder.events
        #expect(cancelledSubmissionEvents.map(\.kind) == [.session, .prompt, .response])
        let close = try #require(cancelledSubmissionEvents.last)
        #expect(close.text == nil)
        #expect(close.ms != nil)

        // Nothing was left half-written: an ordinary answer on the same session
        // records its own whole prompt/response pair straight after. Run through
        // `followUpAnswerCompletes` rather than awaited directly, so a regression
        // that stranded the pump fails here instead of suspending the follow-up
        // answer — and the suite with it — forever.
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        let afterEvents = await fixture.recorder.events
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

        #expect(await sessionA.cancel() == .requested)
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
        #expect(await session.cancel() == .requested)
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
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }
}
