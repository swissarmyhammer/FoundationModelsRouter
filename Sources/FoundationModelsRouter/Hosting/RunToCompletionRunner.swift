import Foundation
import FoundationModels
import Tracing

/// A decorator that runs each call of the wrapped tool to completion and returns its value in band. A call with no progress past the timeout ends with ``ToolMountError/timedOut(tool:timeoutSeconds:)``.
struct RunToCompletionRunner<
    Arguments: ConvertibleFromGeneratedContent & Sendable
>: Tool, TurnBoundaryTool, ToolDecorator {
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

    /// Runs one call in band and returns the wrapped tool's output.
    ///
    /// The call runs inside one ``RouterTracing/SpanName/tool`` span, nested in
    /// the turn's span, reporting ``RouterTracing/ToolRunKind/foreground``. The
    /// span carries the run's own terminal outcome, so a call that timed out is
    /// distinguishable from one that failed.
    ///
    /// - Throws: The wrapped tool's error, unmodified, or ``ToolMountError/timedOut(tool:timeoutSeconds:)``. `withSpan` records it on the span and raises it again.
    func call(arguments: Arguments) async throws -> String {
        try await ToolCallSpan.withSpan(
            tracer: tracer, toolName: wrapped.name, sessionID: sessionID, runKind: .foreground
        ) { span in
            let settlement = await settle(arguments: arguments)
            if let outcome = settlement.terminal.outcome {
                ToolCallSpan.record(outcome: outcome, on: span)
            }
            return try settlement.result.get()
        }
    }

    /// Opens the run, calls the wrapped tool in band, and settles the run.
    ///
    /// - Parameter arguments: The call's decoded arguments.
    /// - Returns: How the run ended: the in-band result and its terminal event.
    private func settle(arguments: Arguments) async -> RunSettlement {
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
        return await withGenerationLent(across: .toolCall) {
            await run.execute(arguments: arguments)
        }
    }
}
