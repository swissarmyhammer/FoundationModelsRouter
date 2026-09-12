import Foundation
import FoundationModels
import Tracing

/// A decorator that runs each call of the wrapped tool in the background. Every call posts one progress event, tracks the run in the session's `SessionMailbox`, and returns the ``PendingRunEnvelope``.
/// The run settles with exactly one terminal event: on completion, on cancel, or on timeout. Progress resets the timeout and a pending elicitation suspends it.
/// A tool that declares ``BackgroundTool/inlineSettleGrace`` waits that long before it answers, and a run that settles inside the wait puts its result in the same envelope.
struct BackgroundToolRunner<
    Arguments: ConvertibleFromGeneratedContent & Sendable
>: Tool, TurnBoundaryTool, ToolDecorator {
    /// The wrapped tool. Internal so wiring tests can assert the decorator chain.
    let wrapped: any Tool<Arguments, String>

    /// The owning session's identity.
    private let sessionID: ULID

    /// The owning session's mailbox, where each run is tracked.
    private let mailbox: SessionMailbox

    /// The upstream sink every run's events funnel into.
    private let sink: any OperationEventSink

    /// The registration site's `"verb noun"` op, or `nil` to stamp the wrapped tool's own name.
    private let op: String?

    /// How long a run may go with no progress, or `nil` for no clock. A per-call ``BackgroundTool/timeout(from:)`` overrides it.
    let timeout: TimeInterval?

    /// The owning session's tracer, or `nil` to read the bootstrapped tracer at call time.
    private let tracer: (any Tracer)?

    /// The wrapped tool's name.
    var name: String { wrapped.name }

    /// The wrapped tool's description.
    var description: String { wrapped.description }

    /// The wrapped tool's parameter schema.
    var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the schema is included in the tool's instructions.
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped`.
    init(
        wrapping wrapped: any Tool<Arguments, String>,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String? = nil,
        timeout: TimeInterval?,
        tracer: (any Tracer)? = nil
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.op = op
        self.timeout = timeout
        self.tracer = tracer
    }

    /// Starts one call in the background and returns ``PendingRunEnvelope/rendered`` for the run.
    ///
    /// The call runs inside one ``RouterTracing/SpanName/tool`` span, nested in
    /// the turn's span, reporting ``RouterTracing/ToolRunKind/background``. That
    /// span covers the accept-and-launch step the model sees and ends with the
    /// envelope; the run itself settles later, in ``mailbox``, and is measured
    /// by the run plane rather than by this span.
    ///
    /// - Throws: Nothing — the launch cannot fail; `throws` comes from the `Tool` requirement.
    func call(arguments: Arguments) async throws -> String {
        try await ToolCallSpan.withSpan(
            tracer: tracer, toolName: wrapped.name, sessionID: sessionID, runKind: .background
        ) { span in
            let rendered = await launch(arguments: arguments)
            ToolCallSpan.record(outcome: .succeeded, on: span)
            return rendered
        }
    }

    /// Opens one run, hands its body to a background task, tracks it in
    /// ``mailbox``, and returns the envelope the model is handed in its place.
    ///
    /// A tool that declares ``BackgroundTool/inlineSettleGrace`` gets one more
    /// step: this waits that long for the run it just started. A run that
    /// settles inside the grace is answered with the settled envelope, which
    /// carries the result itself. See
    /// ``settledEnvelope(for:awaiting:within:)``.
    ///
    /// - Parameter arguments: The call's decoded arguments.
    /// - Returns: ``PendingRunEnvelope/rendered`` for the launched run.
    private func launch(arguments: Arguments) async -> String {
        let run = ToolRun(
            wrapped: wrapped,
            arguments: arguments,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            op: op,
            mountTimeout: timeout
        )
        let completionToken = run.context.completionToken
        let envelope = PendingRunEnvelope(
            completionToken: completionToken,
            next: collectInstruction(forCompletionToken: completionToken)
        )
        await run.open()
        await run.funnel.post(
            event: OperationEvent(
                tool: run.context.tool,
                op: run.context.op,
                correlationID: completionToken,
                kind: .progress,
                detail: envelope.rendered
            )
        )
        // The body waits on the start gate until the run is tracked, so it
        // can never settle before the mailbox knows it.
        let start = RaceGate<Void>()
        let work = Task {
            await withCheckedContinuation { start.register(continuation: $0) }
            return await withGenerationLent(across: .backgroundRun) {
                await run.execute(arguments: arguments)
            }
        }
        await mailbox.track(
            tool: run.context.tool,
            op: run.context.op,
            kind: runKind,
            completionToken: completionToken,
            settling: Task { await work.value.terminal },
            canceler: canceler(forCompletionToken: completionToken, work: work, run: run)
        )
        start.resume(with: ())
        guard
            let settled = await settledEnvelope(
                for: completionToken, awaiting: work, within: parameterProvider?.inlineSettleGrace
            )
        else {
            return envelope.rendered
        }
        return settled.rendered
    }

    /// Waits up to `grace` for the run under `completionToken`, and builds the
    /// envelope that carries its result.
    ///
    /// **Why the wait is here.** The model pays one round trip for every
    /// handle it must collect. A run of a few seconds is the common case, and
    /// for that run the handle costs more than the work. A short wait here
    /// gives the model the result in the same tool output, and the model then
    /// calls no `wait` tool at all. A run that is still going when `grace`
    /// elapses is unaffected: the caller answers with the pending envelope,
    /// and the run goes on behind it.
    ///
    /// The wait never cancels the run and never removes it from the mailbox.
    /// The run settles itself, and the mailbox keeps its terminal, so a model
    /// that calls `wait` on the token anyway still gets the same result.
    ///
    /// The staged copy of the run's events is withdrawn when the result goes
    /// out inline. Without that, the outbox would put the same result in front
    /// of the next prompt, and the model would read one result two times. The
    /// journal keeps its own copy either way, so the transcript and the host
    /// events do not change.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token.
    ///   - work: The task that runs the body.
    ///   - grace: How long to wait, or `nil` to not wait at all.
    /// - Returns: The settled envelope, or `nil` when the run is still going.
    private func settledEnvelope(
        for completionToken: String,
        awaiting work: Task<RunSettlement, Never>,
        within grace: TimeInterval?
    ) async -> PendingRunEnvelope? {
        guard let grace, grace > 0 else { return nil }
        let gate = RaceGate<OperationEvent?>()
        let settling = Task { gate.resume(with: await work.value.terminal) }
        let expiry = Task {
            try? await Task.sleep(nanoseconds: SessionMailbox.boundedNanoseconds(clamping: grace))
            gate.resume(with: nil)
        }
        let terminal = await withCheckedContinuation { gate.register(continuation: $0) }
        settling.cancel()
        expiry.cancel()
        // A terminal with no outcome states nothing about how the run ended,
        // so the caller answers with the pending envelope and the model
        // collects the run through `wait` as usual.
        guard let terminal, let outcome = terminal.outcome else { return nil }
        await withdrawStagedEvents(of: completionToken)
        return PendingRunEnvelope(
            completionToken: completionToken,
            outcome: outcome.rawValue,
            detail: SessionMailbox.boundingDetail(terminal).detail,
            next: resultInstruction(forCompletionToken: completionToken)
        )
    }

    /// Takes back every event the run under `completionToken` staged for a
    /// later prompt, when the sink stages events at all.
    ///
    /// - Parameter completionToken: The run's completion token.
    private func withdrawStagedEvents(of completionToken: String) async {
        guard let outbox = sink as? any StagedEventWithdrawing else { return }
        await outbox.withdrawStagedEvents(correlationID: completionToken)
    }

    /// The wrapped tool as a declarer of its own parameters, or `nil`.
    private var parameterProvider: (any BackgroundTool)? {
        wrapped as? any BackgroundTool
    }

    /// The wrapped tool's own `next` sentence, or the default.
    private func collectInstruction(forCompletionToken completionToken: String) -> String {
        guard let provider = parameterProvider else {
            return PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
        }
        return provider.collectInstruction(forCompletionToken: completionToken)
    }

    /// The wrapped tool's own sentence for a settled run, or the default.
    private func resultInstruction(forCompletionToken completionToken: String) -> String {
        guard let provider = parameterProvider else {
            return PendingRunEnvelope.defaultResultInstruction(forCompletionToken: completionToken)
        }
        return provider.resultInstruction(forCompletionToken: completionToken)
    }

    /// The wrapped tool's declared ``RunKind``, or ``RunKind/swiftTask``.
    private var runKind: RunKind {
        parameterProvider?.runKind ?? .swiftTask
    }

    /// The wrapped tool's own canceler, or the cooperative one that requests the run stop and reports ``OperationOutcome/cancelled``.
    /// A ``RunKind/process`` run's canceler is authoritative: its outcome becomes the run's terminal outcome.
    private func canceler(
        forCompletionToken completionToken: String,
        work: Task<RunSettlement, Never>,
        run: ToolRun<Arguments>
    ) -> @Sendable () async -> OperationOutcome {
        if let supplied = parameterProvider?.canceler(forCompletionToken: completionToken) {
            guard runKind == .process else {
                return supplied
            }
            return { await run.stop(using: supplied) }
        }
        return {
            run.requestCancellation()
            work.cancel()
            return .cancelled
        }
    }
}
