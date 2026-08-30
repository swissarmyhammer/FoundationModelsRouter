import Foundation
import FoundationModels
import Tracing

/// A decorator that binds a per-call ``ToolContext`` around a non-`String`-output tool and returns its output unchanged. It synthesizes no events.
struct ContextBindingTool<
    Arguments: ConvertibleFromGeneratedContent, Output: PromptRepresentable
>: Tool, TurnBoundaryTool, ToolDecorator {
    /// The wrapped tool. Internal so wiring tests can assert the decorator chain.
    let wrapped: any Tool<Arguments, Output>

    /// The owning session's identity.
    private let sessionID: ULID

    /// The owning session's mailbox, carried for ``ToolContext/elicit(_:)``.
    private let mailbox: SessionMailbox

    /// The upstream sink the bound context posts the tool's events to.
    private let sink: any OperationEventSink

    /// The registration site's `"verb noun"` op, or `nil` to stamp the wrapped tool's own name.
    private let op: String?

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

    /// Wraps `wrapped` in the binding-only decorator.
    init(
        wrapping wrapped: any Tool<Arguments, Output>,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String? = nil,
        tracer: (any Tracer)? = nil
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.op = op
        self.tracer = tracer
    }

    /// Runs one call under a fresh ``ToolContext`` binding, posts an open and a close ``ToolInvocationRecord`` around it, and rethrows the wrapped tool's error unmodified.
    ///
    /// The call runs inside one ``RouterTracing/SpanName/tool`` span, nested in
    /// the turn's span, reporting ``RouterTracing/ToolRunKind/foreground``.
    ///
    /// - Throws: The wrapped tool's error, unmodified. `withSpan` records it on the span and raises it again.
    func call(arguments: Arguments) async throws -> Output {
        try await ToolCallSpan.withSpan(
            tracer: tracer, toolName: wrapped.name, sessionID: sessionID, runKind: .foreground
        ) { span in
            try await bind(arguments: arguments, reportingTo: span)
        }
    }

    /// The bound call itself: the per-call ``ToolContext``, the pair of
    /// ``ToolInvocationRecord``s around it, and the outcome written onto `span`.
    ///
    /// - Parameters:
    ///   - arguments: The call's decoded arguments.
    ///   - span: This call's own tool span.
    /// - Returns: The wrapped tool's output, unchanged.
    /// - Throws: The wrapped tool's error, unmodified.
    private func bind(arguments: Arguments, reportingTo span: any Span) async throws -> Output {
        let cancellationFlag = CancellationRequestFlag()
        let context = ToolContext(
            stamping: wrapped,
            op: op,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { cancellationFlag.isRequested }
        )
        let openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
        await sink.post(invocation: openRecord)
        return try await withTaskCancellationHandler {
            // Captured as a `Result` so the close record is posted on the
            // throwing path too — `defer` cannot await.
            let outcome: Result<Output, any Error>
            do {
                outcome = .success(
                    try await withGenerationLent(across: .toolCall) {
                        try await ToolContext.$current.withValue(context) {
                            try await wrapped.call(arguments: arguments)
                        }
                    })
            } catch {
                outcome = .failure(error)
            }
            await sink.post(invocation: openRecord.closed(at: Date()))
            let recorded: OperationOutcome =
                switch outcome {
                case .success: .succeeded
                case .failure: .failed
                }
            ToolCallSpan.record(outcome: recorded, on: span)
            return try outcome.get()
        } onCancel: {
            cancellationFlag.request()
        }
    }
}
