import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the ambient ``ToolContext`` task local (task ^b3arjr3): binding
/// visibility through `ToolContext.$current.withValue`, the capture-at-start
/// rule (a detached task sees `nil`), nil-safe no-op posting, the phase-1
/// tool/op stamping rule for a plain wrapped `Tool`, correlation stamping on
/// `post(_:)`/`progress(_:)`, and the `elicit(_:)` round trip through a real
/// ``SessionMailbox`` — accept with content, decline, cancel, and two
/// concurrent elicitations on one run resolving independently.
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

        func post(_ event: OperationEvent) {
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

        func post(_ event: OperationEvent) async {
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

    @Test("a detached task inside the binding does not inherit the context")
    func detachedTaskSeesNil() async throws {
        let context = Self.makeContext(sink: RecordingSink())

        await ToolContext.$current.withValue(context) {
            #expect(ToolContext.current != nil)
            let detachedSawContext = await Task.detached {
                ToolContext.current != nil
            }.value
            #expect(!detachedSawContext)
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

        let answering = Task {
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

        let answer = try await answering.value
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

        let answering = Task { try await context.elicit(request) }

        try await Self.waitUntilPending([request.elicitationId], in: mailbox)
        await mailbox.respond(elicitationId: request.elicitationId, .decline)

        let answer = try await answering.value
        #expect(answer.action == .decline)
        #expect(answer.content == nil)
    }

    @Test("elicit resumes on cancel, with no content")
    func elicitCancelRoundTrip() async throws {
        let mailbox = SessionMailbox()
        let context = Self.makeContext(sink: RecordingSink(), mailbox: mailbox)
        let request = Self.formRequest()

        let answering = Task { try await context.elicit(request) }

        try await Self.waitUntilPending([request.elicitationId], in: mailbox)
        await mailbox.respond(elicitationId: request.elicitationId, .cancel)

        let answer = try await answering.value
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

        let firstAnswering = Task { try await context.elicit(first) }
        let secondAnswering = Task { try await context.elicit(second) }

        try await Self.waitUntilPending(
            [first.elicitationId, second.elicitationId], in: mailbox
        )

        // Answer out of registration order, each addressed by its own id.
        await mailbox.respond(
            elicitationId: second.elicitationId,
            .accept(content: ["name": .string("Grace")])
        )
        await mailbox.respond(elicitationId: first.elicitationId, .decline)

        let firstAnswer = try await firstAnswering.value
        let secondAnswer = try await secondAnswering.value
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
        // The sink answers from inside `post(_:)` itself — no polling, no
        // scheduling gap the registration could hide behind. If the pending
        // entry were not registered before the post, this respond would
        // no-op and elicit would suspend forever.
        let sink = ImmediatelyRespondingSink(mailbox: mailbox, response: .decline)
        let context = Self.makeContext(sink: sink, mailbox: mailbox)

        let answer = try await context.elicit(Self.formRequest())

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
}
