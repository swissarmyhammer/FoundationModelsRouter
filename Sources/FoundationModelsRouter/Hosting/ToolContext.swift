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
/// Event field sourcing for a plain wrapped `Tool` (`OperationEvent.tool` and
/// `.op` are non-optional and the journal's `renderedLine(for:)` consumes
/// both): the binder stamps ``tool`` with the wrapped tool's `name` — the
/// session-visible tool identity — and ``op`` with the canonical
/// `"verb noun"` string the registration site declared for this mount,
/// falling back to that same `name` when the site declares none. Both are
/// stamped into the context at bind time, never left empty (see
/// ``init(stamping:op:sessionID:mailbox:sink:completionToken:isCancelled:)``,
/// which also states which plane the declared pair appears on).
public struct ToolContext: Sendable {
    /// The context bound to the current task, or `nil` outside any binding —
    /// including inside a detached task started under one (the
    /// capture-at-start rule above).
    @TaskLocal public static var current: ToolContext?

    // MARK: - Run-plane bounds

    /// The largest seconds-valued deadline the run plane honors, in seconds
    /// (one day). A larger — or infinite — requested deadline is clamped here
    /// rather than trapped on: the run stays running past the clamp, so a
    /// caller can simply wait again.
    ///
    /// One ceiling bounds every such deadline, which is why the name says
    /// "deadline" rather than naming one clock:
    /// ``wait(completionToken:seconds:)``'s own deadline, a
    /// `DetachConfiguration.waitSeconds` window, and a
    /// `DetachConfiguration.timeout` window all clamp against it.
    ///
    /// Published because a host clamps a model-supplied deadline against it
    /// before it ever reaches the run plane, and reports the clamp it made.
    public static let deadlineSecondsCeiling: Double = 86_400

    /// The maximum character count of a terminal event's `detail` as the run
    /// plane reports it — the bound behind
    /// "``wait(completionToken:seconds:)`` returns a bounded output tail,
    /// never a capability's full store". A longer detail is truncated to its
    /// trailing `terminalDetailTailLimit` characters (the tail — the end of
    /// the output is what a caller acts on), so the run identifier plus a
    /// capped tail is all that ever leaves the run plane.
    ///
    /// Published because a host asserts its own rendered output tail against
    /// it, so what it hands a model is never wider than what it was given.
    public static let terminalDetailTailLimit = 4_096

    // MARK: - Session scope

    /// The owning session's identity — ``RoutedSession/id``.
    public let sessionID: ULID

    /// The owning session's mailbox: where ``elicit(_:)`` suspends its pending
    /// continuation, keyed by the request's `elicitationId`, and the run
    /// plane the three run-plane capabilities below read.
    ///
    /// Internal, deliberately: a tool reaches elicitation through the typed
    /// ``elicit(_:)`` capability (task ^j0pp9yp) and the run plane through
    /// ``backgroundRuns()``, ``wait(completionToken:seconds:)`` and
    /// ``cancel(completionToken:)`` (task ^k0mecjp) — never through the raw
    /// mailbox. The binder supplies the mailbox at construction and keeps its
    /// own reference when it needs one.
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
    /// posts. Never empty — see the stamping rule above.
    public let tool: String

    /// The op string stamped on every event this run posts. Never empty: the
    /// canonical `"verb noun"` string the mount's registration site declared,
    /// or the wrapped tool's `name` when it declared none.
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

    /// Creates a context for a plain wrapped `Tool`, stamping its identity:
    /// ``tool`` takes the wrapped tool's `name`, and ``op`` takes `op` when
    /// the mount's registration site declared one and that same `name`
    /// otherwise. Neither is ever left empty — a tool whose `name` is empty
    /// falls back to its type name, so the stamp survives the journal's
    /// non-optional `OperationEvent.tool`/`.op` fields regardless of the
    /// conformer.
    ///
    /// A capability verb cannot supply its own `op`, which is why it arrives
    /// here rather than off the tool: the canonical `"verb noun"` pair —
    /// `"execute shell"` for `tools.shell.execute` — needs the noun, and the
    /// noun belongs to the `register(noun:tool:)` site that mounts the verb,
    /// never to the verb. That site declares it through
    /// ``ToolDetachment/wrapping(tool:inheriting:sink:op:configuration:)`` or
    /// ``ToolDetachment/wrapping(tool:sessionID:mailbox:sink:op:configuration:)``,
    /// and the two decorators carry it in here.
    ///
    /// ### The plane the declared pair appears on
    ///
    /// It appears on the **run plane**, and there alone: ``BackgroundRun/op``,
    /// which ``backgroundRuns()`` reports, and ``ToolInvocationRecord/op``, which
    /// the binding layers post through
    /// ``OperationEventSink/post(invocation:)``. Both are built from this
    /// context's stamps directly, so both carry the declared string verbatim.
    ///
    /// It does **not** appear in the event journal of an enclosing snippet.
    /// ``post(_:)`` re-stamps every event it forwards with its own run's
    /// ``tool``, ``op`` and ``completionToken``, so an inner `tools.*` call
    /// mounted inside a `runCode` snippet — whose sink posts through the
    /// snippet's own captured context — reaches the session outbox under the
    /// OUTER run's op. That journal is the enclosing run's, and it is meant to
    /// read as one operation. A test that looked for the declared op there
    /// would be asserting the wrong plane.
    ///
    /// - Parameters:
    ///   - tool: The plain wrapped tool whose `name` (or, when that is
    ///     empty, whose type name) stamps ``tool``.
    ///   - op: The canonical `"verb noun"` op the mount's registration site
    ///     declares, or `nil` — the default — to stamp the tool's own name
    ///     into ``op`` as well. An empty string reads as `nil`, exactly as an
    ///     empty `name` falls back to the type name, so a declaration that
    ///     came out empty degrades to the existing behaviour rather than
    ///     tripping the explicit initializer's precondition.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink capabilities post through.
    ///   - completionToken: The run's completion token; also the
    ///     `correlationID` on every posted event.
    ///   - isCancelled: Reports whether the run's cancellation has been
    ///     requested.
    public init(
        stamping tool: any Tool,
        op: String? = nil,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) {
        let stamp = tool.name.isEmpty ? String(describing: type(of: tool)) : tool.name
        let declared = op.flatMap { $0.isEmpty ? nil : $0 }
        self.init(
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            tool: stamp,
            op: declared ?? stamp,
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
    /// detachment, with no second machinery: the run suspends as a pending
    /// promise in the session's mailbox (keyed by the request's
    /// `elicitationId`), the request rides the event chain upstream as an
    /// elicitation-kind event on this run's correlation, and the answer
    /// comes down through ``SessionMailbox/respond(elicitationId:_:)`` and
    /// resumes the suspended continuation. One run can hold several pending
    /// elicitations at once — each answer addresses its own id.
    ///
    /// Registration happens-before the post: the mailbox installs the
    /// pending entry first and only then starts the upstream post (see
    /// ``SessionMailbox/awaitAnswer(to:posting:)``), so an answer delivered
    /// the instant a host observes the posted event always finds the pending
    /// entry — never a dropped answer.
    ///
    /// Cancellation of the calling task does not resume a pending
    /// elicitation: the suspension resumes only through
    /// ``SessionMailbox/respond(elicitationId:_:)``,
    /// ``SessionMailbox/complete(elicitationId:)``, or the session-teardown
    /// ``SessionMailbox/sweep()`` (which rejects it with
    /// ``ElicitationResponse/cancel``). The current implementation never
    /// throws; the `throws` reserves the error channel of the pinned
    /// signature.
    ///
    /// - Parameter request: The typed request whose `elicitationId` keys the
    ///   suspended continuation.
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

    // MARK: - Run-plane capabilities

    /// Every run still running on this session's run plane, in tracking order.
    ///
    /// The host route onto the run plane (task ^k0mecjp): a tool host that
    /// shows the plane to a model renders these rows, and never holds the
    /// session's mailbox to get them. Each row carries envelopes only — the
    /// run's token, identity, kind, and latest progress — never a
    /// capability's bulk output.
    ///
    /// - Returns: One ``BackgroundRun`` per still-background run.
    public func backgroundRuns() async -> [BackgroundRun] {
        await mailbox.backgroundRuns()
    }

    /// Awaits a background run's settlement with a deadline.
    ///
    /// The result is the run's terminal event — its bounded output tail
    /// (capped at ``terminalDetailTailLimit``) plus the run's identifier —
    /// never a capability's full store. A run that already settled resolves
    /// immediately, and an unknown token is a safe, reportable no-op.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - seconds: How long to wait for settlement before reporting
    ///     ``WaitOutcome/deadlineElapsed``. A model-supplied deadline is
    ///     clamped rather than trusted: NaN and negative values floor to an
    ///     immediate deadline, and anything above ``deadlineSecondsCeiling``
    ///     (including infinity) is capped there — never a trap.
    /// - Returns: The ``WaitOutcome``.
    public func wait(completionToken: String, seconds: Double) async -> WaitOutcome {
        await mailbox.wait(completionToken: completionToken, seconds: seconds)
    }

    /// Requests cancellation of a background run and reports the outcome its
    /// canceler reports — verbatim, never a guess.
    ///
    /// The run stays running until it actually settles, and the reported
    /// outcome says how much the canceler knows. A ``RunKind/swiftTask`` run
    /// is cancelled cooperatively, so the body ends on its own schedule and
    /// the canceler reports ``OperationOutcome/cancelled``. A
    /// ``RunKind/process`` run is killed with `killpg(SIGKILL)` by the
    /// capability that owns the group, so the canceler reports
    /// ``OperationOutcome/stopped``. Either way,
    /// ``wait(completionToken:seconds:)`` is what collects the terminal event.
    ///
    /// - Parameter completionToken: The run's completion token.
    /// - Returns: The ``CancelOutcome``.
    public func cancel(completionToken: String) async -> CancelOutcome {
        await mailbox.cancel(completionToken: completionToken)
    }
}
