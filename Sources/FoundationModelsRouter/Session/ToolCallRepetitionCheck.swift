import FoundationModels
import FoundationModelsExtras

/// The repetition check that runs before each tool body of one model call
/// (task ^dzw15st).
///
/// The backend shows a tool call only after the model ended it, and the SDK
/// then runs the tool. So the watch of a generation pass cannot stop a tool
/// call whose arguments repeat one line again and again. The session binds
/// one check for each model call on the task of the submission, as it binds
/// the tool-result boundary (`ToolResultAppendBoundary`), and the SDK gives
/// it to each tool body that it runs inside the call. The live backend gives
/// the SDK session each tool in a ``RepetitionCheckedTool``, over every layer
/// of the session mount, and that decorator runs the check before the tool
/// body. A check that finds a repeated tool call stops the model call, and
/// the tool body does not run.
struct ToolCallRepetitionCheck: Sendable {
    /// The check of the model call that the current task runs in, or `nil`
    /// outside a model call.
    @TaskLocal static var current: ToolCallRepetitionCheck?

    /// The session operation that checks the tool call.
    private let check: @Sendable () async throws -> Void

    /// Makes the check of one model call.
    ///
    /// - Parameter check: The session operation that checks the tool call. It
    ///   throws when the tool body must not run.
    init(check: @escaping @Sendable () async throws -> Void) {
        self.check = check
    }

    /// Runs the check.
    ///
    /// - Throws: `CancellationError` when the session stopped the model call
    ///   for repetition.
    func run() async throws {
        try await check()
    }

    /// Wraps `tool` in a ``RepetitionCheckedTool``, whatever its argument
    /// and output types.
    ///
    /// - Parameter tool: The tool to wrap.
    /// - Returns: The checked tool.
    static func makeChecked(tool: any Tool) -> any Tool {
        func open<Wrapped: Tool>(_ tool: Wrapped) -> any Tool {
            RepetitionCheckedTool(wrapped: tool)
        }
        return open(tool)
    }
}

/// A `Tool` decorator that runs the ``ToolCallRepetitionCheck`` of the
/// current model call before the wrapped tool runs (task ^dzw15st).
///
/// A call outside a model call, where no check is bound, runs the wrapped
/// tool at once.
struct RepetitionCheckedTool<Wrapped: Tool>: Tool, SubmissionBoundaryTool, ToolDecorator {
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

    /// Runs the check of the current model call, then the wrapped tool.
    ///
    /// - Parameter arguments: The arguments of the call, passed through.
    /// - Returns: What the wrapped tool returns.
    /// - Throws: `CancellationError` when the check stopped the model call,
    ///   and what the wrapped tool throws.
    func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        try await ToolCallRepetitionCheck.current?.run()
        return try await wrapped.call(arguments: arguments)
    }
}
