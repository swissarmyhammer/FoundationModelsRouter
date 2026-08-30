import FoundationModels

/// The task-local capability surface a running tool reads: the session's
/// mailbox, sink, and identity, plus the run's `completionToken`, `tool`, and
/// `op` stamps.
///
/// The invoker binds the context around each wrapped call with
/// `ToolContext.$current.withValue(context)`. A task that inherits no
/// task locals does not see it, so capture the context one time, at operation start.
public struct ToolContext: Sendable {
    /// The context bound to the current task, or `nil` outside any binding.
    @TaskLocal public static var current: ToolContext?

    // MARK: - Run-plane bounds

    /// The largest deadline the run plane honors, in seconds (one day). A larger
    /// or infinite deadline is clamped to this value.
    public static let deadlineSecondsCeiling: Double = 86_400

    /// The maximum character count of a terminal event's `detail`. A longer
    /// detail is truncated to its trailing characters.
    public static let terminalDetailTailLimit = 4_096

    // MARK: - Session scope

    /// The owning session's identity — ``RoutedSession/id``.
    public let sessionID: ULID

    /// The owning session's mailbox. A tool reaches it only through the typed
    /// capabilities on this context.
    let mailbox: SessionMailbox

    /// The upstream sink every capability posts through.
    private let sink: any OperationEventSink

    /// The invoker-supplied probe behind ``isCancelled``.
    private let cancellationProbe: @Sendable () -> Bool

    /// Whether cancellation has been requested, as reported by the bound probe.
    var isCancelled: Bool {
        cancellationProbe()
    }

    // MARK: - Run scope

    /// The tool identity stamped on every event this run posts. Never empty.
    public let tool: String

    /// The `"verb noun"` op string stamped on every event this run posts. Never empty.
    public let op: String

    /// The run's completion token; also the `correlationID` on every event this run posts.
    public let completionToken: String

    /// Creates a context with every field explicit.
    ///
    /// - Parameters:
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink capabilities post through.
    ///   - tool: The tool identity stamp. Must not be empty (precondition).
    ///   - op: The op stamp. Must not be empty (precondition).
    ///   - completionToken: The run's completion token.
    ///   - isCancelled: Reports whether cancellation has been requested.
    init(
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

    /// Creates a context for a plain wrapped `Tool` and stamps its identity.
    ///
    /// ``tool`` takes the tool's `name`, or its type name when `name` is empty.
    /// ``op`` takes `op` when the registration site declared one, else the same
    /// stamp as ``tool``. An empty `op` reads as `nil`.
    ///
    /// The declared `op` appears on the run plane (``BackgroundRun/op`` and
    /// ``ToolInvocationRecord/op``). ``post(_:)`` re-stamps every forwarded event
    /// with this run's stamps, so an inner call inside an enclosing run reaches
    /// the journal under the outer run's op.
    ///
    /// - Parameters:
    ///   - tool: The wrapped tool.
    ///   - op: The declared `"verb noun"` op, or `nil`.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink capabilities post through.
    ///   - completionToken: The run's completion token.
    ///   - isCancelled: Reports whether cancellation has been requested.
    init(
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

    /// Posts `event` upstream, re-stamped with this run's ``tool``, ``op``, and
    /// ``completionToken``. Only `kind`, `detail`, `outcome`, and `elicitation`
    /// survive the re-stamp.
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

    /// Posts a `.progress` event upstream with `detail`, stamped as ``post(_:)`` stamps it.
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

    /// Asks the user a question in the middle of the run.
    ///
    /// The run suspends in the session's mailbox, keyed by the request's
    /// `elicitationId`, and the request rides upstream as an elicitation event.
    /// The suspension resumes only through
    /// `SessionMailbox.respond(elicitationId:_:)`,
    /// `SessionMailbox.complete(elicitationId:)`, or `SessionMailbox.sweep()`.
    /// Task cancellation does not resume it. The current implementation never throws.
    ///
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

    /// Every background run on this session, in tracking order. Envelopes only, never bulk output.
    public func backgroundRuns() async -> [BackgroundRun] {
        await mailbox.backgroundRuns()
    }

    /// Awaits a background run's settlement with a deadline. The result is the
    /// run's terminal event with its detail capped at ``terminalDetailTailLimit``.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - seconds: The deadline. NaN and negative values floor to zero; values
    ///     above ``deadlineSecondsCeiling`` are capped there.
    /// - Returns: The ``WaitOutcome``.
    public func wait(completionToken: String, seconds: Double) async -> WaitOutcome {
        await mailbox.wait(completionToken: completionToken, seconds: seconds)
    }

    /// Requests cancellation of a background run and reports its canceler's
    /// outcome verbatim. The run stays running until it settles;
    /// ``wait(completionToken:seconds:)`` collects the terminal event.
    ///
    /// - Returns: The ``CancelOutcome``.
    public func cancel(completionToken: String) async -> CancelOutcome {
        await mailbox.cancel(completionToken: completionToken)
    }

    // MARK: - Mounting capability

    /// Mounts `tool` on this run's session plane and hands back the mounted
    /// tool, ready to call.
    ///
    /// This is the entry point a binder that dispatches its own inner tool
    /// calls — a scripting seam, a multitool façade — mounts each call through.
    /// The mounted tool carries the same machinery a session-registered tool
    /// carries: a per-call ``ToolContext`` of its own, a run tracked in this
    /// session's mailbox, a per-call tracing span, and, for a background mount,
    /// a completion-token handle returned at once.
    ///
    /// A `String`-output tool becomes a background or a run-to-completion
    /// runner, per the mount it declares through ``BackgroundTool/mount`` or,
    /// when it declares none, per `configuration`. Any other output becomes a
    /// binding-only decorator, which returns the tool's own output unchanged.
    /// Every one of them keeps `T`'s `Arguments` and `Output`, so the result
    /// needs no cast.
    ///
    /// The mounted run's events route through ``post(_:)``, which re-stamps
    /// each one with this run's ``tool``, ``op``, and ``completionToken``. So
    /// the inner run reaches the session's outbox under the correlation of the
    /// operation the session actually issued, while the inner run's own
    /// completion token stays on the run plane, where
    /// ``backgroundRuns()`` and the inner tool's own ``ToolContext/current``
    /// read it.
    ///
    /// The span each call opens resolves late, through
    /// `InstrumentationSystem.tracer` at call time, so an application that
    /// bootstraps a tracing backend after it mounts still traces.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The `"verb noun"` op the mounted run journals as its `op`, or
    ///     `nil` to stamp the tool's own name.
    ///   - configuration: The mount to use when `tool` declares none of its
    ///     own. Defaults to ``ToolMount/synchronous``.
    /// - Returns: The mounted tool, at `tool`'s own `Arguments` and `Output`.
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous
    ) -> any Tool<T.Arguments, T.Output> {
        let mounted = ToolMounting.makeWrapped(
            tool: tool,
            inheriting: self,
            sink: MountedRunUpstreamSink(context: self),
            op: op,
            configuration: configuration,
            tracer: nil
        )
        // Unreachable: every decorator preserves `Arguments`/`Output`, and
        // `ToolMounting.makeWrapped`'s own unreachable fallback returns the
        // tool itself, which matches too. `tool` is a graceful degradation
        // rather than a trap — the call still happens, only unmounted.
        return mounted as? any Tool<T.Arguments, T.Output> ?? tool
    }
}

/// The upstream end of a mounted run's event route: the sink
/// ``ToolContext/mount(_:op:as:)`` hands the mount layer, forwarding every
/// event the run produces through the ``ToolContext`` that mounted it.
///
/// ``ToolContext/post(_:)`` is the only egress a context publishes, and it
/// re-stamps what it forwards with its own identity. So a mounted run's events
/// reach the session's outbox on the mounting run's correlation, while the
/// mounted run's own completion token stays on the run plane.
private struct MountedRunUpstreamSink: OperationEventSink {
    /// The mounting context every event is forwarded through.
    let context: ToolContext

    func post(event: OperationEvent) async {
        await context.post(event)
    }
}
