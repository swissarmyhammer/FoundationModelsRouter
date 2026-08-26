import Foundation
import FoundationModels

/// A decorator that runs each call of the wrapped tool to completion and
/// returns its value in band. An optional timeout ends a call that makes no
/// progress with ``DetachingToolError/timedOut(tool:timeoutSeconds:)``. It
/// owns the call's correlation and event plumbing, nothing else.
public struct RunToCompletionTool<Arguments: ConvertibleFromGeneratedContent & Sendable>: Tool {
    /// The wrapped tool. Internal so wiring tests can assert the decorator chain.
    let wrapped: any Tool<Arguments, String>

    /// The owning session's identity.
    private let sessionID: ULID

    /// The owning session's mailbox.
    private let mailbox: SessionMailbox

    /// The upstream sink every run's events funnel into.
    private let sink: any OperationEventSink

    /// The registration site's `"verb noun"` op, or `nil` to stamp the
    /// wrapped tool's own name.
    private let op: String?

    /// How long a call may run with no progress, or `nil` for no clock.
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
    ///   - timeout: How long a call may run with no progress, or `nil`.
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

    /// Runs one call in band and returns the wrapped tool's output.
    ///
    /// - Parameter arguments: The call's arguments, forwarded untouched.
    /// - Returns: The wrapped tool's output.
    /// - Throws: Whatever the wrapped tool throws, unmodified, or
    ///   ``DetachingToolError/timedOut(tool:timeoutSeconds:)``.
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
        await run.open()
        // The model is suspended on this call, so the turn's generation
        // permit may be lent across it.
        let settlement = await withGenerationLent(across: .toolCall) {
            await run.execute(arguments: arguments)
        }
        return try settlement.result.get()
    }
}
