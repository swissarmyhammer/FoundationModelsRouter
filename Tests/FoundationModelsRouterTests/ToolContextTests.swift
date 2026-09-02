import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the ambient ``ToolContext`` task local (task ^b3arjr3): binding
/// visibility through `ToolContext.$current.withValue`, the capture-at-start
/// rule (work that inherits no task-locals sees `nil`), nil-safe no-op posting, the phase-1
/// tool/op stamping rule for a plain wrapped `Tool`, correlation stamping on
/// `post(_:)`/`progress(_:)`, and the `elicit(_:)` round trip through a real
/// `SessionMailbox` — accept with content, decline, cancel, and two
/// concurrent elicitations on one run resolving independently.
///
/// The run-plane capabilities a tool host reads (task ^k0mecjp) are exercised
/// here too: `backgroundRuns()`, `wait(completionToken:seconds:)` and
/// `cancel(completionToken:)`, each driven against a real `SessionMailbox`
/// holding a fake background run — no live model anywhere.
@Suite("ToolContext: ambient task-local capability surface")
struct ToolContextTests {
    // MARK: - Fixtures

    @Generable
    struct ContextToolArguments {
        let value: String
    }

    /// A plain `FoundationModels.Tool` with nothing but a name — the phase-1
    /// stamping rule's subject: the binder stamps both `tool` and `op` with
    /// this name.
    private struct PlainNamedTool: Tool {
        let name = "demo_tool"
        let description = "test-only plain tool with only a name"

        func call(arguments: ContextToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    /// A tool whose `name` is empty — the subject of the stamping fallback:
    /// binding it must still stamp non-empty `tool`/`op`.
    private struct EmptyNamedTool: Tool {
        let name = ""
        let description = "test-only tool with an empty name"

        func call(arguments: ContextToolArguments) async throws -> String {
            "handled: \(arguments.value)"
        }
    }

    /// A sink that records every posted event, in order.
    private actor RecordingSink: OperationEventSink {
        private(set) var events: [OperationEvent] = []

        func post(event: OperationEvent) {
            events.append(event)
        }
    }

    /// A sink that answers an elicitation the instant it observes the posted
    /// event — the answer-arrives-immediately path, with no polling anywhere.
    private actor ImmediatelyRespondingSink: OperationEventSink {
        private let mailbox: SessionMailbox
        private let response: ElicitationResponse

        init(mailbox: SessionMailbox, response: ElicitationResponse) {
            self.mailbox = mailbox
            self.response = response
        }

        func post(event: OperationEvent) async {
            guard let request = event.elicitation else { return }
            await mailbox.respond(elicitationId: request.elicitationId, response)
        }
    }

    /// The error ``waitUntilPending(_:in:)`` throws when its attempts are
    /// exhausted, so a caller aborts instead of driving a respond that
    /// no-ops and an await that never resumes.
    private struct PendingElicitationTimeout: Error {}

    /// Builds a context bound to `sink` per the phase-1 stamping rule
    /// (`tool` and `op` both stamped with ``PlainNamedTool``'s name).
    private static func makeContext(
        sink: any OperationEventSink,
        mailbox: SessionMailbox = SessionMailbox(),
        sessionID: ULID = ULID.generate(),
        completionToken: String = SessionMailbox.makeCompletionToken(),
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> ToolContext {
        ToolContext(
            stamping: PlainNamedTool(),
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: completionToken,
            isCancelled: isCancelled
        )
    }

    /// Polls the mailbox until every id in `elicitationIds` is pending, or
    /// fails after a bounded number of attempts — never an unbounded hang.
    private static func waitUntilPending(
        _ elicitationIds: [ULID], in mailbox: SessionMailbox
    ) async throws {
        for _ in 0..<1_000 {
            let pending = await mailbox.pendingElicitationIds()
            if elicitationIds.allSatisfy(pending.contains) {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("elicitations \(elicitationIds) never became pending")
        throw PendingElicitationTimeout()
    }

    /// The ceiling on any await a run-plane test performs against the
    /// mailbox — long enough that a settled run is never missed, and it is
    /// never actually waited out.
    private static let settlementDeadline: Double = 30

    /// A deadline short enough that a run which never settles elapses it
    /// while the suite stays fast.
    private static let elapsingDeadline: Double = 0.05

    /// A single-string-field form request addressed by `elicitationId`.
    private static func formRequest(elicitationId: ULID = ULID.generate()) -> ElicitationRequest {
        ElicitationRequest(
            message: "What is your name?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(
                properties: ["name": .string(ElicitationStringSchema())]
            )
        )
    }

    // MARK: - Token minting

    @Test("the published mint gives a token of the shape the mailbox's own mint gives")
    func publishedMintMatchesTheMailboxTokenShape() {
        let published = ToolContext.makeCompletionToken()
        let mailboxMinted = SessionMailbox.makeCompletionToken()

        // The shape is the canonical ULID string, and it is load-bearing: the
        // run plane keys a tracked run by this token and stamps it as the
        // event `correlationID`, so a token of any other shape could never
        // name a run either side of that boundary recognizes.
        #expect(ULID(published) != nil)
        #expect(ULID(mailboxMinted) != nil)
        #expect(published.count == ULID.stringLength)
        #expect(mailboxMinted.count == published.count)
    }

    // MARK: - Binding visibility

    @Test("a body inside withValue sees the bound context; outside it sees nil")
    func bindingVisibility() async throws {
        let sessionID = ULID.generate()
        let completionToken = SessionMailbox.makeCompletionToken()
        let context = Self.makeContext(
            sink: RecordingSink(), sessionID: sessionID, completionToken: completionToken
        )

        #expect(ToolContext.current == nil)
        ToolContext.$current.withValue(context) {
            let current = ToolContext.current
            #expect(current != nil)
            #expect(current?.sessionID == sessionID)
            #expect(current?.completionToken == completionToken)
            #expect(current?.tool == "demo_tool")
            #expect(current?.op == "demo_tool")
        }
        #expect(ToolContext.current == nil)
    }

    @Test("work that inherits no task-locals, started inside the binding, does not see the context")
    func nonInheritingWorkSeesNil() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        await ToolContext.$current.withValue(context) {
            #expect(ToolContext.current != nil)
            // A raw thread inherits no task-locals, so the probe reads the
            // context the way any non-inheriting work would.
            let probeSawContext = await withCheckedContinuation { continuation in
                Thread {
                    continuation.resume(returning: ToolContext.current != nil)
                }.start()
            }
            #expect(!probeSawContext)
        }
    }

    @Test("cancellation reports what the invoker's probe reports")
    func cancellationReflectsProbe() async throws {
        let live = Self.makeContext(sink: RecordingSink(), isCancelled: { false })
        #expect(!live.isCancelled)

        let cancelled = Self.makeContext(sink: RecordingSink(), isCancelled: { true })
        #expect(cancelled.isCancelled)
    }

    // MARK: - Nil-safe no-op posting

    @Test("posting through a nil current context is a safe no-op")
    func nilCurrentPostIsNoOp() async throws {
        let sink = RecordingSink()
        // A context exists and is wired to the sink — but is never bound, so
        // `ToolContext.current` stays nil and optional-chained capability
        // calls do nothing at all.
        _ = Self.makeContext(sink: sink)

        #expect(ToolContext.current == nil)
        await ToolContext.current?.progress("never delivered")
        await ToolContext.current?.post(
            OperationEvent(
                tool: "", op: "", correlationID: "", kind: .completed,
                detail: "never delivered", outcome: .succeeded
            )
        )

        #expect(await sink.events.isEmpty)
    }

    // MARK: - Correlation and phase-1 tool/op stamping

    @Test("progress(_:) builds a .progress event stamped with the run's identity")
    func progressCarriesRunIdentity() async throws {
        let sink = RecordingSink()
        let completionToken = SessionMailbox.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.progress("halfway")

        let events = await sink.events
        #expect(events.count == 1)
        #expect(events.first?.kind == .progress)
        #expect(events.first?.detail == "halfway")
        #expect(events.first?.correlationID == completionToken)
        #expect(events.first?.tool == "demo_tool")
        #expect(events.first?.op == "demo_tool")
    }

    @Test("post(_:) re-stamps tool/op/correlationID; the tool never supplies them")
    func postCarriesRunIdentityWithoutToolSupplyingIt() async throws {
        let sink = RecordingSink()
        let completionToken = SessionMailbox.makeCompletionToken()
        let context = Self.makeContext(sink: sink, completionToken: completionToken)

        await context.post(
            OperationEvent(
                tool: "", op: "", correlationID: "", kind: .completed,
                detail: "done", outcome: .succeeded
            )
        )

        let events = await sink.events
        #expect(events.count == 1)
        let posted = try #require(events.first)
        #expect(posted.kind == .completed)
        #expect(posted.detail == "done")
        #expect(posted.outcome == .succeeded)
        // The phase-1 stamping rule: both identity fields carry the wrapped
        // tool's name — never empty — and the correlation is the run's token.
        #expect(posted.tool == "demo_tool")
        #expect(posted.op == "demo_tool")
        #expect(!posted.tool.isEmpty)
        #expect(!posted.op.isEmpty)
        #expect(posted.correlationID == completionToken)
    }

    // MARK: - Elicitation round trip

    @Test("elicit suspends, posts the request upstream, and resumes on accept with content")
    func elicitAcceptRoundTrip() async throws {
        let sink = RecordingSink()
        let mailbox = SessionMailbox()
        let completionToken = SessionMailbox.makeCompletionToken()
        let context = Self.makeContext(
            sink: sink, mailbox: mailbox, completionToken: completionToken
        )
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await ToolContext.$current.withValue(context) {
                let current = try #require(ToolContext.current)
                return try await current.elicit(request)
            }
        }

        try await Self.waitUntilPending([request.elicitationId], in: mailbox)
        await mailbox.respond(
            elicitationId: request.elicitationId,
            .accept(content: ["name": .string("Ada")])
        )

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .accept)
        #expect(answer.content == ["name": .string("Ada")])

        // The request rode the event chain as an elicitation-kind event on
        // the run's correlation, stamped per the phase-1 rule.
        let events = await sink.events
        #expect(events.count == 1)
        let posted = try #require(events.first)
        #expect(posted.kind == .elicitation)
        #expect(posted.elicitation == request)
        #expect(posted.correlationID == completionToken)
        #expect(posted.tool == "demo_tool")
        #expect(posted.op == "demo_tool")
    }

    @Test("elicit resumes on decline, with no content")
    func elicitDeclineRoundTrip() async throws {
        let mailbox = SessionMailbox()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }

        try await Self.waitUntilPending([request.elicitationId], in: mailbox)
        await mailbox.respond(elicitationId: request.elicitationId, .decline)

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .decline)
        #expect(answer.content == nil)
    }

    @Test("elicit resumes on cancel, with no content")
    func elicitCancelRoundTrip() async throws {
        let mailbox = SessionMailbox()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let request = Self.formRequest()

        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }

        try await Self.waitUntilPending([request.elicitationId], in: mailbox)
        await mailbox.respond(elicitationId: request.elicitationId, .cancel)

        let answer = try await answering.deliveredAnswer()
        #expect(answer.action == .cancel)
        #expect(answer.content == nil)
    }

    @Test("two concurrent elicitations on one run resolve independently by elicitationId")
    func concurrentDoubleElicit() async throws {
        let sink = RecordingSink()
        let mailbox = SessionMailbox()
        let context = Self.makeContext(sink: sink, mailbox: mailbox)
        let first = Self.formRequest()
        let second = Self.formRequest()

        let firstAnswering = AnswerDrivenRun(waitingFor: "the elicitation \(first.elicitationId)") {
            try await context.elicit(first)
        }
        let secondAnswering = AnswerDrivenRun(waitingFor: "the elicitation \(second.elicitationId)") {
            try await context.elicit(second)
        }

        try await Self.waitUntilPending(
            [first.elicitationId, second.elicitationId], in: mailbox
        )

        // Answer out of registration order, each addressed by its own id.
        await mailbox.respond(
            elicitationId: second.elicitationId,
            .accept(content: ["name": .string("Grace")])
        )
        await mailbox.respond(elicitationId: first.elicitationId, .decline)

        let firstAnswer = try await firstAnswering.deliveredAnswer()
        let secondAnswer = try await secondAnswering.deliveredAnswer()
        #expect(firstAnswer.action == .decline)
        #expect(firstAnswer.content == nil)
        #expect(secondAnswer.action == .accept)
        #expect(secondAnswer.content == ["name": .string("Grace")])

        // Both requests rode the event chain on the same run correlation.
        let events = await sink.events
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.kind == .elicitation })
        let carried = Set(events.compactMap { $0.elicitation?.elicitationId })
        #expect(carried == [first.elicitationId, second.elicitationId])
    }

    @Test("elicit registers before posting: an answer arriving the instant the event is observed is delivered, never dropped")
    func elicitAnswerArrivingImmediatelyIsDelivered() async throws {
        let mailbox = SessionMailbox()
        // The sink answers from inside `post(event:)` itself — no polling, no
        // scheduling gap the registration could hide behind. If the pending
        // entry were not registered before the post, this respond would
        // no-op and elicit would suspend forever.
        let sink = ImmediatelyRespondingSink(mailbox: mailbox, response: .decline)
        let context = Self.makeContext(sink: sink, mailbox: mailbox)

        let request = Self.formRequest()
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(request.elicitationId)") {
            try await context.elicit(request)
        }
        let answer = try await answering.deliveredAnswer()

        #expect(answer.action == .decline)
        #expect(answer.content == nil)
    }

    @Test("stamping a tool with an empty name falls back to its type name — tool/op are never empty")
    func stampingEmptyNamedToolNeverStampsEmpty() async throws {
        let sink = RecordingSink()
        let context = ToolContext(
            stamping: EmptyNamedTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false }
        )

        #expect(context.tool == "EmptyNamedTool")
        #expect(context.op == "EmptyNamedTool")

        await context.progress("still stamped")

        let posted = try #require(await sink.events.first)
        #expect(!posted.tool.isEmpty)
        #expect(!posted.op.isEmpty)
    }

    // MARK: - Attachments

    @Test("attach hands each record to the sink the context was built with, in call order")
    func attachRoutesToTheBoundSink() {
        let box = ToolCallAttachmentBox()
        let context = ToolContext(
            stamping: PlainNamedTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: RecordingSink(),
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false },
            attachmentSink: { box.append($0) }
        )

        context.attach(MountFixtures.firstAttachment)
        context.attach(MountFixtures.secondAttachment)

        #expect(box.drain() == MountFixtures.attachmentsInCallOrder)
        // A drain empties the box: the same records never deliver twice.
        #expect(box.drain().isEmpty)
    }

    @Test("attach on a context built with the default sink drops the record: no event carries it, and the call does not trap")
    func attachOnTheDefaultSinkDrops() async {
        let sink = RecordingSink()
        let context = Self.makeContext(sink: sink)

        context.attach(MountFixtures.firstAttachment)

        // An attachment is never an event: the event route stays silent.
        #expect(await sink.events.isEmpty)
    }

    // MARK: - Run-plane capabilities

    @Test("backgroundRuns() reports the session's background runs, and a settled run leaves the report")
    func backgroundRunsReportsTheSessionsRuns() async throws {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: "exit 0")

        let runs = await context.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.completionToken == token)
        #expect(runs.first?.tool == FakeRun.tool)
        #expect(runs.first?.op == FakeRun.op)
        #expect(runs.first?.kind == .swiftTask)
        #expect(runs.first?.latestProgressDetail == nil)

        await mailbox.updateProgress(completionToken: token, detail: "50%")
        #expect(await context.backgroundRuns().first?.latestProgressDetail == "50%")

        await latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
        #expect(await context.backgroundRuns().isEmpty)
    }

    @Test("wait() resolves to the run's terminal event once it settles")
    func waitResolvesToTheTerminalEvent() async throws {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: "exit 0")

        await latch.open()
        let outcome = await context.wait(
            completionToken: token, seconds: Self.settlementDeadline
        )

        guard case .settled(let terminal) = outcome else {
            Issue.record("expected .settled, got \(outcome)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.detail == "exit 0")
        #expect(terminal.outcome == .succeeded)
    }

    @Test("wait() reports its deadline elapsing and leaves the run tracked")
    func waitReportsTheDeadlineElapsing() async throws {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let token = await trackFakeRun(on: mailbox, latch: latch)

        #expect(
            await context.wait(completionToken: token, seconds: Self.elapsingDeadline)
                == .deadlineElapsed
        )
        #expect(await context.backgroundRuns().count == 1)

        // Settle the fake run so the test tears down with no suspended
        // continuation left behind.
        await latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
    }

    @Test("wait() on a token no run is known under is a safe, reportable no-op")
    func waitReportsAnUnknownToken() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        let outcome = await context.wait(
            completionToken: SessionMailbox.makeCompletionToken(),
            seconds: Self.settlementDeadline
        )

        #expect(outcome == .unknownToken)
    }

    @Test("cancel() reports the outcome the run's canceler reports")
    func cancelReportsTheCancelersOutcome() async throws {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let token = await trackFakeRun(on: mailbox, latch: latch, cancelerOutcome: .cancelled)

        #expect(await context.cancel(completionToken: token) == .reported(.cancelled))

        // The cancelled run settles on its own schedule; collect it so the
        // test leaves nothing suspended.
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
    }

    @Test("cancel() on a run that already settled reports its retained terminal event")
    func cancelReportsAnAlreadySettledRun() async throws {
        let mailbox = SessionMailbox()
        let latch = RunLatch()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let token = await trackFakeRun(on: mailbox, latch: latch, detailOnSettle: "exit 0")

        await latch.open()
        _ = await context.wait(completionToken: token, seconds: Self.settlementDeadline)
        let outcome = await context.cancel(completionToken: token)

        guard case .alreadySettled(let terminal) = outcome else {
            Issue.record("expected .alreadySettled, got \(outcome)")
            return
        }
        #expect(terminal.correlationID == token)
        #expect(terminal.outcome == .succeeded)
    }

    @Test("cancel() on a token no run is known under is a safe, reportable no-op")
    func cancelReportsAnUnknownToken() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        let outcome = await context.cancel(
            completionToken: SessionMailbox.makeCompletionToken()
        )

        #expect(outcome == .unknownToken)
    }
}
