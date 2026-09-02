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

    /// The bound call itself: the settlement of one call, and its outcome
    /// written onto `span`.
    ///
    /// - Parameters:
    ///   - arguments: The call's decoded arguments.
    ///   - span: This call's own tool span.
    /// - Returns: The wrapped tool's output, unchanged.
    /// - Throws: The wrapped tool's error, unmodified.
    private func bind(arguments: Arguments, reportingTo span: any Span) async throws -> Output {
        let settlement = await settle(arguments: arguments)
        ToolCallSpan.record(outcome: settlement.recordedOutcome, on: span)
        return try settlement.outcome.get()
    }

    /// Runs one call under a fresh ``ToolContext`` binding, posts the open and
    /// the close ``ToolInvocationRecord`` around it, and drains the records the
    /// call attached.
    ///
    /// The settlement holds the drained attachments beside the outcome. A
    /// later card posts them from ``bind(arguments:reportingTo:)``.
    ///
    /// - Parameter arguments: The call's decoded arguments.
    /// - Returns: How the call ended, and what it attached.
    func settle(arguments: Arguments) async -> BindingSettlement<Output> {
        let cancellationFlag = CancellationRequestFlag()
        let attachmentBox = ToolCallAttachmentBox()
        let context = ToolContext(
            stamping: wrapped,
            op: op,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { cancellationFlag.isRequested },
            attachmentSink: { attachmentBox.append($0) }
        )
        let openRecord = ToolInvocationRecord(
            tool: context.tool,
            op: context.op,
            correlationID: context.completionToken,
            sessionID: sessionID,
            openedAt: Date()
        )
        await sink.post(invocation: openRecord)
        return await withTaskCancellationHandler {
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
            // Drained after the call returns. A record the tool attaches
            // later than this point belongs to no settlement, and is dropped.
            let attachments = attachmentBox.drain()
            await sink.post(invocation: openRecord.closed(at: Date()))
            return BindingSettlement(outcome: outcome, attachments: attachments)
        } onCancel: {
            cancellationFlag.request()
        }
    }
}

/// How one bound call ended: the wrapped tool's outcome, and the records the
/// call attached.
struct BindingSettlement<Output> {
    /// The wrapped tool's output, or the error that ended the call.
    let outcome: Result<Output, any Error>

    /// The records the tool attached through ``ToolContext/attach(_:)``, in
    /// call order.
    let attachments: [ToolCallAttachment]

    /// The outcome the call's span records: succeeded for an output, failed
    /// for an error.
    var recordedOutcome: OperationOutcome {
        switch outcome {
        case .success: .succeeded
        case .failure: .failed
        }
    }
}
