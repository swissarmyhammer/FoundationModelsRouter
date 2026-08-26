import Foundation
import FoundationModels

/// A decorator that runs each call of the wrapped tool to completion and returns its value in band. A call with no progress past the timeout ends with ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
struct RunToCompletionRunner<Arguments: ConvertibleFromGeneratedContent & Sendable>: Tool {
    /// The wrapped tool. Internal so wiring tests can assert the decorator chain.
    let wrapped: any Tool<Arguments, String>

    /// The owning session's identity.
    private let sessionID: ULID

    /// The owning session's mailbox.
    private let mailbox: SessionMailbox

    /// The upstream sink every run's events funnel into.
    private let sink: any OperationEventSink

    /// The registration site's `"verb noun"` op, or `nil` to stamp the wrapped tool's own name.
    private let op: String?

    /// How long a call may run with no progress, or `nil` for no clock. A per-call ``BackgroundTool/timeout(from:)`` overrides it.
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

    /// Runs one call in band and returns the wrapped tool's output.
    /// - Throws: The wrapped tool's error, unmodified, or ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
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
        await run.open()
        // The model is suspended on this call, so the turn's generation
        // permit may be lent across it.
        let settlement = await withGenerationLent(across: .toolCall) {
            await run.execute(arguments: arguments)
        }
        return try settlement.result.get()
    }
}
