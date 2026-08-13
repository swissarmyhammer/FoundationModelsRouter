import FoundationModels

/// The ambient, task-local capability surface a running tool reads: the
/// session's mailbox, upstream event sink, and identity (session scope), plus
/// the one run's `completionToken`/`tool`/`op` stamps (run scope — the
/// invoker mints a fresh `completionToken` into each binding).
///
/// The invoker binds the context around each wrapped call —
/// `ToolContext.$current.withValue(context) { try await tool.call(arguments:) }`
/// — so there is no second tool protocol: the registry keeps `any Tool`, a
/// conformer reads ``current`` when it wants capabilities and ignores it
/// otherwise, and every existing conformer works without change.
///
/// Capture-at-start is an enforced rule, not a request: a detached task does
/// not inherit task locals, so a tool that starts detached work and then
/// reads the ambient context again finds `nil` — and a post through `nil` is
/// already a safe no-op. Capture the context one time, at operation start,
/// into the object that continues after the call.
///
/// Event field sourcing for a plain wrapped `Tool` (the phase-1 stamping
/// rule; `OperationEvent.tool` and `.op` are non-optional and the journal's
/// `renderedLine(for:)` consumes both): the binder stamps ``tool`` with the
/// wrapped tool's `name` — the session-visible tool identity — and ``op``
/// with that same `name`, until noun/verb registration lands in phase 2 and
/// supplies the canonical `"verb noun"` string. Both are stamped into the
/// context at bind time, never left empty (see ``init(stamping:sessionID:mailbox:sink:completionToken:isCancelled:)``).
public struct ToolContext: Sendable {
    /// The context bound to the current task, or `nil` outside any binding —
    /// including inside a detached task started under one (the
    /// capture-at-start rule above).
    @TaskLocal public static var current: ToolContext?

    // MARK: - Session scope

    /// The owning session's identity — ``RoutedSession/id``.
    public let sessionID: ULID

    /// The owning session's mailbox: where ``elicit(_:)`` parks its pending
    /// continuation, keyed by the request's `elicitationId`.
    ///
    /// Internal, deliberately: a tool reaches elicitation through the typed
    /// ``elicit(_:)`` capability, never through the raw mailbox (task
    /// ^j0pp9yp). The binder supplies the mailbox at construction and keeps
    /// its own reference when it needs one.
    let mailbox: SessionMailbox

    /// The upstream sink every capability posts through.
    private let sink: any OperationEventSink

    /// The invoker-supplied probe behind ``isCancelled``.
    private let cancellationProbe: @Sendable () -> Bool

    /// Whether cancellation has been requested, as reported by the probe the
    /// invoker bound — verbatim, never a guess from whichever task happens to
    /// read it.
    public var isCancelled: Bool {
        cancellationProbe()
    }

    // MARK: - Run scope

    /// The session-visible tool identity stamped on every event this run
    /// posts. Never empty — see the phase-1 stamping rule above.
    public let tool: String

    /// The op string stamped on every event this run posts. Never empty:
    /// phase 1 stamps the wrapped tool's `name` here too, until noun/verb
    /// registration supplies the canonical `"verb noun"` string.
    public let op: String

    /// The run's completion token — the ULID string (see
    /// ``SessionMailbox/makeCompletionToken()``) that is also the
    /// `correlationID` on every event this run posts. Minted by the invoker
    /// at each binding: run scope, never session scope.
    public let completionToken: String

    /// Creates a context with every field explicit.
    ///
    /// - Parameters:
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink capabilities post through.
    ///   - tool: The session-visible tool identity stamped on every posted
    ///     event. Must not be empty — enforced with a precondition, because
    ///     `OperationEvent.tool` is non-optional and the journal's
    ///     `renderedLine(for:)` consumes it.
    ///   - op: The op string stamped on every posted event. Must not be
    ///     empty — enforced with a precondition, exactly as `tool` is.
    ///   - completionToken: The run's completion token; also the
    ///     `correlationID` on every posted event.
    ///   - isCancelled: Reports whether the run's cancellation has been
    ///     requested.
    public init(
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        precondition(!tool.isEmpty, "a ToolContext's tool stamp must not be empty")
        precondition(!op.isEmpty, "a ToolContext's op stamp must not be empty")
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.tool = tool
        self.op = op
        self.completionToken = completionToken
        self.cancellationProbe = isCancelled
    }

    /// Creates a context for a plain wrapped `Tool` per the phase-1 stamping
    /// rule: both ``tool`` and ``op`` are stamped with the wrapped tool's
    /// `name`, never left empty — a tool whose `name` is empty falls back to
    /// its type name, so the stamp survives the journal's non-optional
    /// `OperationEvent.tool`/`.op` fields regardless of the conformer.
    ///
    /// - Parameters:
    ///   - tool: The plain wrapped tool whose `name` (or, when that is
    ///     empty, whose type name) stamps both identity fields.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink capabilities post through.
    ///   - completionToken: The run's completion token; also the
    ///     `correlationID` on every posted event.
    ///   - isCancelled: Reports whether the run's cancellation has been
    ///     requested.
    public init(
        stamping tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        let stamp = tool.name.isEmpty ? String(describing: type(of: tool)) : tool.name
        self.init(
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            tool: stamp,
            op: stamp,
            completionToken: completionToken,
            isCancelled: isCancelled
        )
    }

    // MARK: - Capabilities

    /// Posts `event` upstream, re-stamped with this run's identity: the
    /// forwarded event carries the context's ``tool``, ``op``, and
    /// ``completionToken`` (as its `correlationID`) — the tool never
    /// supplies them, and whatever identity fields `event` carried are
    /// replaced.
    ///
    /// - Parameter event: The event to forward; only its `kind`, `detail`,
    ///   `outcome`, and `elicitation` survive the re-stamp.
    public func post(_ event: OperationEvent) async {
        await sink.post(
            event: OperationEvent(
                tool: tool,
                op: op,
                correlationID: completionToken,
                kind: event.kind,
                detail: event.detail,
                outcome: event.outcome,
                elicitation: event.elicitation
            )
        )
    }

    /// Posts a `.progress` event upstream carrying `detail`, stamped with
    /// this run's identity exactly as ``post(_:)`` stamps it.
    ///
    /// - Parameter detail: The run's newest progress detail.
    public func progress(_ detail: String) async {
        await sink.post(
            event: OperationEvent(
                tool: tool,
                op: op,
                correlationID: completionToken,
                kind: .progress,
                detail: detail
            )
        )
    }

    /// Asks the user a question in the middle of the run — only another
    /// detachment, with no second machinery: the run parks as a pending
    /// promise in the session's mailbox (keyed by the request's
    /// `elicitationId`), the request rides the event chain upstream as an
    /// elicitation-kind event on this run's correlation, and the answer
    /// comes down through ``SessionMailbox/respond(elicitationId:_:)`` and
    /// resumes the parked continuation. One run can hold several pending
    /// elicitations at once — each answer addresses its own id.
    ///
    /// Registration happens-before the post: the mailbox installs the
    /// pending entry first and only then starts the upstream post (see
    /// ``SessionMailbox/awaitAnswer(to:posting:)``), so an answer delivered
    /// the instant a host observes the posted event always finds the pending
    /// entry — never a dropped answer.
    ///
    /// Cancellation of the calling task does not unpark a pending
    /// elicitation: the suspension resumes only through
    /// ``SessionMailbox/respond(elicitationId:_:)``,
    /// ``SessionMailbox/complete(elicitationId:)``, or the session-teardown
    /// ``SessionMailbox/sweep()`` (which rejects it with
    /// ``ElicitationResponse/cancel``). The current implementation never
    /// throws; the `throws` reserves the error channel of the pinned
    /// signature.
    ///
    /// - Parameter request: The typed request whose `elicitationId` keys the
    ///   parked continuation.
    /// - Returns: The user's answer.
    public func elicit(_ request: ElicitationRequest) async throws -> ElicitationResponse {
        let event = OperationEvent(
            tool: tool,
            op: op,
            correlationID: completionToken,
            kind: .elicitation,
            detail: "",
            elicitation: request
        )
        let sink = self.sink
        return await mailbox.awaitAnswer(to: request) {
            await sink.post(event: event)
        }
    }
}
