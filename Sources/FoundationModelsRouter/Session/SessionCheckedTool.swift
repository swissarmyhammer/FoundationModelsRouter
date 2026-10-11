import FoundationModels
import FoundationModelsExtras

/// A `Tool` decorator that runs the checks of the current model call before
/// the wrapped tool runs: first the no-op check (``ToolCallNoOpCheck``, task
/// ^rw72f4j), then the repetition check (``ToolCallRepetitionCheck``, task
/// ^dzw15st).
///
/// The backend shows a tool call only after the model ended it, and the SDK
/// then runs the tool. So the session can stop a tool call only before its
/// body runs. The live backend gives the SDK session each tool in this
/// decorator, over every layer of the session mount
/// (`Tool.sessionChecked`). A check that stops the model call throws, and the
/// tool body does not run.
///
/// A call outside a model call, where no check is bound, runs the wrapped
/// tool at once.
struct SessionCheckedTool<Wrapped: Tool>: Tool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: Wrapped

    /// The name of the wrapped tool.
    var name: String { wrapped.name }

    /// The description of the wrapped tool.
    var description: String { wrapped.description }

    /// The parameters of the wrapped tool.
    var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the wrapped tool puts its schema in the instructions.
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Runs the checks of the current model call, then the wrapped tool.
    ///
    /// The no-op check gets the name of the tool and the generated content
    /// of `arguments`. The repetition check gets the identity of this call:
    /// the name of the tool and the JSON text of `arguments` (task ^8eq31j0).
    ///
    /// - Parameter arguments: The arguments of the call, passed through.
    /// - Returns: What the wrapped tool returns.
    /// - Throws: `CancellationError` when a check stopped the model call, and
    ///   what the wrapped tool throws.
    func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        let content = (arguments as? any ConvertibleToGeneratedContent)?.generatedContent
        try await ToolCallNoOpCheck.current?.run(toolName: name, arguments: content)
        try await ToolCallRepetitionCheck.current?.run(for: ToolCallIdentity(toolName: name, arguments: arguments))
        return try await wrapped.call(arguments: arguments)
    }
}

/// The checks that ``SessionCheckedTool`` runs before each tool body of one
/// model call: the no-op check and the repetition check. The session makes
/// one value for each model call, and binds both task-locals around the call
/// (``bound(_:)``).
struct ModelCallToolChecks: Sendable {
    /// The no-op check of the model call (task ^rw72f4j).
    let noOp: ToolCallNoOpCheck

    /// The repetition check of the model call (task ^dzw15st).
    let repetition: ToolCallRepetitionCheck

    /// Runs `body` with both checks bound as the checks of the current model
    /// call.
    ///
    /// - Parameter body: The model call.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func bound<Result: Sendable>(_ body: () async throws -> Result) async throws -> Result {
        try await ToolCallNoOpCheck.$current.withValue(noOp) {
            try await ToolCallRepetitionCheck.$current.withValue(repetition) {
                try await body()
            }
        }
    }
}

extension Tool {
    /// This tool in a ``SessionCheckedTool``, whatever its argument and
    /// output types. A call on an `any Tool` value opens the existential, so
    /// the decorator wraps the concrete tool.
    var sessionChecked: any Tool {
        SessionCheckedTool(wrapped: self)
    }
}
