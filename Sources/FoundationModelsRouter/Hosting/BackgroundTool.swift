import Foundation
import FoundationModels

/// A decorator that runs each call of the wrapped tool in the background.
/// Every call posts one synthesized progress event, tracks the run in the
/// session's ``SessionMailbox``, then releases the body and returns the
/// ``PendingRunEnvelope`` — also when the body completes in microseconds.
///
/// The run settles with exactly one terminal event: on natural completion,
/// on cancel through the canceler the wrapped tool declares (or the
/// cooperative one), or on timeout, which progress resets and a pending
/// elicitation suspends. The body borrows the parent turn's generation
/// permit for its whole life.
public struct BackgroundTool<Arguments: ConvertibleFromGeneratedContent & Sendable>: Tool {
    /// The wrapped tool. Internal so wiring tests can assert the decorator chain.
    let wrapped: any Tool<Arguments, String>

    /// The owning session's identity.
    private let sessionID: ULID

    /// The owning session's mailbox, where each run is tracked.
    private let mailbox: SessionMailbox

    /// The upstream sink every run's events funnel into.
    private let sink: any OperationEventSink

    /// The registration site's `"verb noun"` op, or `nil` to stamp the
    /// wrapped tool's own name.
    private let op: String?

    /// How long a run may go with no progress, or `nil` for no clock.
    /// A per-call ``DetachmentParameterProviding/detachmentTimeout(from:)``
    /// overrides it.
    let timeout: TimeInterval?

    /// The wrapped tool's name.
    public var name: String { wrapped.name }

    /// The wrapped tool's description.
    public var description: String { wrapped.description }

    /// The wrapped tool's parameter schema.
    public var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the schema is included in the tool's instructions.
    public var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The tool to decorate.
    ///   - sessionID: The owning session's identity.
    ///   - mailbox: The owning session's mailbox.
    ///   - sink: The upstream sink the run's events are posted to.
    ///   - op: The registration site's `"verb noun"` op, or `nil`.
    ///   - timeout: How long a run may go with no progress, or `nil`.
    public init(
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

    /// Starts one call in the background and returns its pending envelope.
    ///
    /// - Parameter arguments: The call's arguments, forwarded untouched.
    /// - Returns: ``PendingRunEnvelope/rendered`` for the run.
    public func call(arguments: Arguments) async throws -> String {
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
    private var parameterProvider: (any DetachmentParameterProviding)? {
        wrapped as? any DetachmentParameterProviding
    }

    /// The wrapped tool's own `next` sentence, or the default.
    private func collectInstruction(forCompletionToken completionToken: String) -> String {
        guard let provider = parameterProvider else {
            return PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: completionToken)
        }
        return provider.detachmentCollectInstruction(forCompletionToken: completionToken)
    }

    /// The wrapped tool's declared ``RunKind``, or ``RunKind/swiftTask``.
    private var runKind: RunKind {
        parameterProvider?.detachmentRunKind ?? .swiftTask
    }

    /// The wrapped tool's own canceler, or the cooperative one: it requests
    /// the run stop through the flag and the work task's cancellation, and
    /// reports exactly that.
    private func canceler(
        forCompletionToken completionToken: String,
        work: Task<RunSettlement, Never>,
        run: ToolRun<Arguments>
    ) -> @Sendable () async -> OperationOutcome {
        if let supplied = parameterProvider?.detachmentCanceler(forCompletionToken: completionToken) {
            return supplied
        }
        return {
            run.requestCancellation()
            work.cancel()
            return .cancelled
        }
    }
}
