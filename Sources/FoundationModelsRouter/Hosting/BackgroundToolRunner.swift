import Foundation
import FoundationModels

/// A decorator that runs each call of the wrapped tool in the background. Every call posts one progress event, tracks the run in the session's ``SessionMailbox``, and returns the ``PendingRunEnvelope`` at once.
/// The run settles with exactly one terminal event: on completion, on cancel, or on timeout. Progress resets the timeout and a pending elicitation suspends it.
struct BackgroundToolRunner<Arguments: ConvertibleFromGeneratedContent & Sendable>: Tool, TurnBoundaryTool {
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
        timeout: TimeInterval?
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.op = op
        self.timeout = timeout
    }

    /// Starts one call in the background and returns ``PendingRunEnvelope/rendered`` for the run.
    func call(arguments: Arguments) async throws -> String {
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
        return envelope.rendered
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

    /// Forwards to the wrapped tool when it conforms, or does nothing — the
    /// background counterpart of ``RunToCompletionRunner/turnWillBegin()``.
    func turnWillBegin() async {
        await (wrapped as? any TurnBoundaryTool)?.turnWillBegin()
    }
}
