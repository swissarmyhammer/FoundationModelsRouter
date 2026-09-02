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

    /// The invoker-supplied destination behind ``attach(_:)``. The default
    /// drops every attachment.
    private let attachmentSink: @Sendable (ToolCallAttachment) -> Void

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
    ///   - attachmentSink: Receives each record the tool attaches. The default
    ///     drops every record.
    init(
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        tool: String,
        op: String,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void = { _ in }
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
        self.attachmentSink = attachmentSink
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
    ///   - attachmentSink: Receives each record the tool attaches. The default
    ///     drops every record.
    init(
        stamping tool: any Tool,
        op: String? = nil,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        completionToken: String,
        isCancelled: @escaping @Sendable () -> Bool,
        attachmentSink: @escaping @Sendable (ToolCallAttachment) -> Void = { _ in }
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
            isCancelled: isCancelled,
            attachmentSink: attachmentSink
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

    /// Hands `attachment` to the run this context belongs to.
    ///
    /// Attachments collect on the run named by ``completionToken``, in call
    /// order. The run delivers them when the call closes (later cards). An
    /// attachment is never rendered to the model, and it never becomes an
    /// `OperationEvent`. A call outside any run, on a context built with the
    /// default sink, drops the attachment.
    ///
    /// - Parameter attachment: The record to attach to this call.
    public func attach(_ attachment: ToolCallAttachment) {
        attachmentSink(attachment)
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

    /// Mounts `tool` on this run's session plane and returns the mounted tool.
    ///
    /// The caller can call the mounted tool at once. A binder that dispatches
    /// its own inner tool calls mounts each call through this entry point. A
    /// scripting layer is one such binder, and a multitool is another.
    ///
    /// The mounted tool gets the same support a session-registered tool gets.
    /// It gets a per-call ``ToolContext`` of its own. It opens a per-call
    /// tracing span. Only a background mount tracks its run in the session's
    /// mailbox. Only a background mount returns a completion-token handle at
    /// once.
    ///
    /// A `String`-output tool becomes a background runner or a
    /// run-to-completion runner. The tool selects one through
    /// ``BackgroundTool/mount``. A tool that declares no mount takes
    /// `configuration` instead. Any other output becomes a binding-only
    /// decorator, which returns the tool's own output unchanged. Each of these
    /// mounts keeps `T`'s `Arguments` and `Output`, so the result needs no
    /// cast.
    ///
    /// **The correlation this overload gives the caller.** ``post(_:)``
    /// forwards every event the mounted run posts. That method re-stamps each
    /// event with this run's ``tool``, ``op``, and ``completionToken``. It
    /// therefore puts what the mounted run posts on the correlation of the
    /// operation the session issued. An application wants that correlation.
    /// The outbox then names the operation the caller asked the session for.
    /// The mounted run's own completion token stays on the run plane.
    /// ``backgroundRuns()`` and the mounted tool's own ``ToolContext/current``
    /// read it there.
    ///
    /// **The correlation the JOURNAL keeps under this overload.** ``post(_:)``
    /// re-stamps each event before the outbox receives it. A posted event
    /// therefore never carries the mounted run's own token. The journal keeps
    /// THIS run's ``completionToken`` for each posted event it records.
    ///
    /// The mounted run's own terminal is the exception. The run stamps that
    /// terminal with its own token, and the session's mailbox receives it
    /// under that token when the run settles, whatever ``post(_:)`` does with
    /// the copy. The mailbox forwards that terminal to the journal under the
    /// run's own token. ``SessionEvent/runSettled(_:)`` therefore fires for a
    /// mounted run, and it carries the run's own token. One mounted background
    /// run can therefore be in the journal under two correlations. THIS run's
    /// token carries what the mounted run posted. The mounted run's own token
    /// carries its terminal.
    ///
    /// A background run that settles posts its natural terminal through
    /// ``post(_:)`` first, under THIS run's correlation. That re-stamped copy
    /// normally stops one hop later, in one of two branches. A mounting run of
    /// a `String`-output tool posts through its own `RunEventFunnel`. That
    /// funnel admits one `.completed` and drops every later one. In the first
    /// branch the mounting run settled first. A background mount returns its
    /// envelope at once, so this is the normal branch. The funnel then drops
    /// the re-stamped copy. The outbox never receives that copy, and the
    /// journal never records it. In the second branch the mounting run is
    /// still open. The re-stamped copy then goes through under the mounting
    /// token, and that copy also sets the mounting funnel's terminal flag. The
    /// mounting run's own `settleRun` then delivers nothing. In both branches
    /// the mailbox forwards the mounted run's own terminal to the journal
    /// under the run's own token.
    ///
    /// ``RoutedSession/close()`` sweeps the session's mailbox. The sweep
    /// produces one terminal event for each background run it still tracks,
    /// and `close()` sends each of those events straight to the journal. Both
    /// overloads show that in the same way. The sweep first runs the run's
    /// canceler, and that call suspends the mailbox. A run that settles in
    /// that window keeps its own natural terminal. The mailbox forwards that
    /// terminal, and the sweep returns the same event. A run that is still
    /// open gets a terminal the mailbox BUILDS. The mailbox stamps a terminal
    /// it builds with the tool, the op, and the token the mount registered.
    /// Both of those terminals carry the MOUNTED run's own completion token.
    /// The journal admits one terminal for each correlation, so `close()`
    /// finds a correlation the mailbox already forwarded claimed, and writes
    /// it no second time.
    ///
    /// A caller can read the mounted run's OWN correlation through
    /// ``mount(_:op:as:postingTo:)``. That overload tells two concurrent runs
    /// of one tool apart. It also lets a caller assert a run's own identity.
    ///
    /// The span each call opens resolves late. It reads
    /// `InstrumentationSystem.tracer` at call time. An application that starts
    /// a tracing backend after it mounts therefore still traces.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The `"verb noun"` op the mounted run journals as its `op`. Pass
    ///     `nil` to stamp the tool's own name.
    ///   - configuration: The mount to use when `tool` declares none of its
    ///     own. Defaults to ``ToolMount/synchronous``.
    /// - Returns: The mounted tool, at `tool`'s own `Arguments` and `Output`.
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous
    ) -> any Tool<T.Arguments, T.Output> {
        mount(tool, op: op, as: configuration, postingTo: MountedRunUpstreamSink(context: self))
    }

    /// Mounts `tool` on this run's session plane and posts each run's events
    /// to `sink`.
    ///
    /// Each mounted run posts its events with the stamps that run applied.
    ///
    /// This overload does everything ``mount(_:op:as:)`` does. It selects the
    /// mount in the same way. It uses the same decorator and the same per-call
    /// ``ToolContext``. It tracks a background run in the same mailbox. It
    /// opens the same span. Only the correlation the caller observes is
    /// different. The call site does not show that difference.
    ///
    /// **The correlation this overload gives the caller.** `sink` reads each
    /// mounted run's own ``completionToken`` as the `correlationID` of every
    /// event that run posts. `sink` is the run's own upstream, so nothing
    /// re-stamps what reaches it. The default overload posts through this
    /// context instead, and puts every event on THIS run's correlation. Use
    /// this overload to tell two concurrent runs of one tool apart. Use it
    /// also to assert a run's own identity. A host that only wants to know
    /// what happened uses ``mount(_:op:as:)``.
    ///
    /// **What `sink` carries.** `sink` carries the events the RUN posts. Those
    /// events come from ``post(_:)``, from ``progress(_:)``, and from the
    /// request ``elicit(_:)`` sends. The terminal event the run's body
    /// produces is the last of them. The mount holds `sink` for the life of
    /// each RUN, not for the life of each call. A background mount returns its
    /// ``PendingRunEnvelope`` at once, and the body continues behind it.
    /// `sink` therefore takes that run's events after `call(arguments:)`
    /// returns, for as long as the run lasts.
    ///
    /// Two mounts post nothing at all. A binding-only mount posts no events of
    /// its own. A run-to-completion run posts no terminal when it posted no
    /// other event and then succeeded.
    ///
    /// **What `sink` does NOT carry.** `sink` does not carry a terminal the
    /// MAILBOX BUILDS. ``RoutedSession/close()`` sweeps the session's MAILBOX,
    /// not the run. The sweep builds a terminal event for a background run
    /// that is still open after its canceler ran. It stamps that event with
    /// the tool, the op, and the token the mount registered. It takes the
    /// detail from the run's latest progress event. `close()` then sends that
    /// event straight to the journal. The run does not post that event, so
    /// `sink` never receives it. Read that terminal from the journal.
    ///
    /// The sweep does not always build that terminal. It first runs the run's
    /// canceler, and that call suspends the mailbox. A run that settles in
    /// that window keeps its own natural terminal. The sweep returns that
    /// event, and the run itself already posted it to `sink`.
    ///
    /// `close()` writes a swept terminal to the journal only when no earlier
    /// write claimed that run's correlation. A `sink` that forwards into this
    /// session's journal can make that earlier write itself. The journal keeps
    /// one terminal for each run, and refuses the second write. A `sink` that
    /// forwards nowhere leaves the sweep's write as the only one.
    ///
    /// **The correlation the JOURNAL keeps under this overload.** The journal
    /// keeps the mounted run's OWN ``completionToken`` on a swept terminal.
    /// Both of the sweep's two terminals carry that token. The mailbox stamps
    /// a terminal it BUILDS with the token the mount registered. The run
    /// itself stamps its own natural terminal with that same token.
    ///
    /// The events the run posts reach `sink` alone. They reach the journal
    /// only when `sink` itself forwards them there. Under ``mount(_:op:as:)``
    /// the journal keeps the MOUNTING run's token for the posted events it
    /// records. It keeps the mounted run's own token for a swept terminal.
    ///
    /// The canceler of a ``RunKind/swiftTask`` run only requests a stop. A run
    /// the sweep cancelled can therefore still finish afterwards. It then
    /// posts a terminal of its own to `sink`. That terminal can carry a
    /// different outcome from the one the journal already keeps.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - op: The `"verb noun"` op the mounted run journals as its `op`. Pass
    ///     `nil` to stamp the tool's own name.
    ///   - configuration: The mount to use when `tool` declares none of its
    ///     own. Defaults to ``ToolMount/synchronous``.
    ///   - sink: The destination every mounted run posts its own events to.
    /// - Returns: The mounted tool, at `tool`'s own `Arguments` and `Output`.
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous,
        postingTo sink: any OperationEventSink
    ) -> any Tool<T.Arguments, T.Output> {
        let mounted = ToolMounting.makeWrapped(
            tool: tool,
            inheriting: self,
            sink: sink,
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

/// This sink is the upstream end of a mounted run's event route.
/// ``ToolContext/mount(_:op:as:)`` gives it to the mount layer. It forwards
/// every event the run POSTS through the ``ToolContext`` that mounted it.
///
/// Every capability on a context stamps what it posts with that context's own
/// ``ToolContext/tool``, ``ToolContext/op`` and ``ToolContext/completionToken``.
/// ``ToolContext/post(_:)``, ``ToolContext/progress(_:)`` and
/// ``ToolContext/elicit(_:)`` each apply those three stamps. This sink forwards
/// through ``ToolContext/post(_:)``, so a mounted run's posted events carry the
/// mounting run's correlation. The mounted run's own completion token stays on
/// the run plane.
///
/// The mounting context's own sink receives what this sink forwards. A mounting
/// run of a `String`-output tool posts through its own `RunEventFunnel`. That
/// funnel admits one `.completed` and drops every later one. A mounted run's
/// re-stamped terminal normally stops at that funnel, because the mounting run
/// settled first. When the mounting run is still open, the copy goes through
/// under the mounting token and sets that funnel's terminal flag instead.
///
/// The mounted run's own terminal does not depend on this sink. The session's
/// mailbox receives it under the run's own token when the run settles, and
/// forwards it to the journal under that token. Nothing this sink forwards
/// carries that token, so the journal accepts that write. A terminal that
/// ``RoutedSession/close()``'s mailbox sweep BUILDS does not pass through here
/// either. The sweep sends that event to the journal itself, under the same
/// token. A run that settles inside the sweep's canceler window keeps its own
/// natural terminal instead. That terminal did pass through here, and the
/// mailbox forwarded it, so the sweep's write of it is refused.
private struct MountedRunUpstreamSink: OperationEventSink {
    /// The mounting context every event is forwarded through.
    let context: ToolContext

    func post(event: OperationEvent) async {
        await context.post(event)
    }
}
