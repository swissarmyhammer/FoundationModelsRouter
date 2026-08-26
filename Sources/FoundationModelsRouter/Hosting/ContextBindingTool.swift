import Foundation
import FoundationModels

/// A decorator that binds a per-call ``ToolContext`` around a non-`String`-output tool and returns its output unchanged. It synthesizes no events.
public struct ContextBindingTool<
    Arguments: ConvertibleFromGeneratedContent, Output: PromptRepresentable
>: Tool {
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

    /// The wrapped tool's name.
    public var name: String { wrapped.name }

    /// The wrapped tool's description.
    public var description: String { wrapped.description }

    /// The wrapped tool's parameter schema.
    public var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the schema is included in the tool's instructions.
    public var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Wraps `wrapped` in the binding-only decorator.
    public init(
        wrapping wrapped: any Tool<Arguments, Output>,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        op: String? = nil
    ) {
        self.wrapped = wrapped
        self.sessionID = sessionID
        self.mailbox = mailbox
        self.sink = sink
        self.op = op
    }

    /// Runs one call under a fresh ``ToolContext`` binding, posts an open and a close ``ToolInvocationRecord`` around it, and rethrows the wrapped tool's error unmodified.
    public func call(arguments: Arguments) async throws -> Output {
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
            return try outcome.get()
        } onCancel: {
            cancellationFlag.request()
        }
    }
}
