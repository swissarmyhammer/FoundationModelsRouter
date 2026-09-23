import FoundationModels

/// How the session mount gives a failed tool call to the model.
///
/// Apple's `LanguageModelSession` runs the calls of one turn together. When one
/// call throws, the session cancels the other calls of the turn, and then it
/// ends the turn, so the model never reads the failure. On the model-facing
/// mount, an ordinary failure therefore must not cross the `Tool.call`
/// boundary as a throw. The decorators of this file give the failure to the
/// model as the call's output, so the model can read it and make another call.
///
/// A true cancellation is different. It stays a throw, or cancellation stops
/// working.
///
/// Only ``ToolMounting/makeSessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:tokenCounter:tracer:)``
/// applies this rule, and it applies it outermost. The mount layers beneath
/// keep their throw. So a caller that is not the model keeps the throw: a tool
/// from ``ToolContext/mount(_:op:as:postingTo:)``, and a tool of the session's
/// list that the caller reaches through ``throwingTool(of:)``.
///
/// Observability does not change. The mount layers beneath record the terminal
/// `.failed` event and the tool span's error before the error reaches this
/// decorator.
enum ToolFailureDelivery {
    /// Wraps `tool` in the decorator that gives a failure to the model.
    ///
    /// A `String`-output tool becomes a ``FailureDeliveringTextTool``, so its
    /// output stays text. Any other tool becomes a
    /// ``FailureDeliveringResultTool``, whose output is a ``ToolCallResult``.
    ///
    /// - Parameter tool: The mounted tool.
    /// - Returns: The decorated tool.
    static func makeWrapped(tool: any Tool) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let textTool = tool as? any Tool<T.Arguments, String> else {
                return FailureDeliveringResultTool<T.Arguments, T.Output>(wrapped: tool)
            }
            return FailureDeliveringTextTool(wrapped: textTool)
        }
        return open(tool)
    }

    /// The tool beneath the failure-delivery decorator, whose failure still
    /// throws.
    ///
    /// A caller that is not the model, and that calls a tool of the session's
    /// model-facing list, uses this to keep the throw contract of the mount
    /// layers.
    ///
    /// - Parameter tool: A tool of the session's model-facing list, or any
    ///   other tool.
    /// - Returns: The tool beneath the decorator, or `tool` itself when it has
    ///   no such decorator.
    static func throwingTool(of tool: any Tool) -> any Tool {
        (tool as? any FailureDeliveringTool)?.throwingTool ?? tool
    }
}

/// A decorator that gives a failure of the tool beneath to the model as the
/// call's output. See ``ToolFailureDelivery``.
protocol FailureDeliveringTool: Tool {
    /// The tool beneath this decorator, whose failure still throws.
    var throwingTool: any Tool { get }
}

/// The failure-delivery decorator for a `String`-output tool. The failure text
/// is the call's `String` output, so the transcript records text as before.
struct FailureDeliveringTextTool<
    Arguments: ConvertibleFromGeneratedContent
>: FailureDeliveringTool, TurnBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, String>

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    var throwingTool: any Tool { wrapped }

    /// Calls `wrapped`, and gives its failure to the model as the output.
    ///
    /// The output then goes to the tool-result append boundary of the model
    /// call (``ToolResultAppendBoundary``), before the model reads it.
    ///
    /// - Returns: The output of `wrapped`, or the text of the failure that
    ///   ended the call.
    /// - Throws: A `CancellationError` that ended the call, unmodified.
    func call(arguments: Arguments) async throws -> String {
        let text = try await ToolCallResult { try await wrapped.call(arguments: arguments) }.text
        await ToolResultAppendBoundary.current?.deliver(
            result: ToolResultAppend(toolName: name, arguments: arguments, text: text))
        return text
    }
}

/// The failure-delivery decorator for a tool whose output is not `String`.
/// The call's output is a ``ToolCallResult``: the output of the tool beneath,
/// or the failure text.
struct FailureDeliveringResultTool<
    Arguments: ConvertibleFromGeneratedContent, WrappedOutput: PromptRepresentable
>: FailureDeliveringTool, TurnBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, WrappedOutput>

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    var throwingTool: any Tool { wrapped }

    /// Calls `wrapped`, and gives its failure to the model as the output.
    ///
    /// The output then goes to the tool-result append boundary of the model
    /// call (``ToolResultAppendBoundary``), before the model reads it.
    ///
    /// - Returns: The output of `wrapped`, or the text of the failure that
    ///   ended the call.
    /// - Throws: A `CancellationError` that ended the call, unmodified.
    func call(arguments: Arguments) async throws -> ToolCallResult<WrappedOutput> {
        let result = try await ToolCallResult { try await wrapped.call(arguments: arguments) }
        await ToolResultAppendBoundary.current?.deliver(
            result: ToolResultAppend(toolName: name, arguments: arguments, result: result))
        return result
    }
}

/// What one model-facing tool call gives to the model: the tool's output, or
/// the text of the failure that ended the call.
///
/// The SDK records a tool output that is `ConvertibleToGeneratedContent` as a
/// structure, and every other output as text. This type conforms to
/// `ConvertibleToGeneratedContent` only when `Output` conforms, so the call
/// keeps the transcript shape of the tool beneath.
enum ToolCallResult<Output: PromptRepresentable>: PromptRepresentable {
    /// The call returned `Output`.
    case output(Output)

    /// The call failed, and the model reads this description of the error.
    case failure(String)

    /// Runs one call, and keeps its output or the text of its failure.
    ///
    /// - Parameter call: The call to run.
    /// - Throws: A `CancellationError` that `call` throws, unmodified. Every
    ///   other error becomes ``failure(_:)``.
    init(catching call: () async throws -> Output) async throws {
        do {
            self = .output(try await call())
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            self = .failure(String(describing: error))
        }
    }

    /// The tool's own prompt, or the failure text as a prompt.
    var promptRepresentation: Prompt {
        switch self {
        case .output(let output):
            return output.promptRepresentation
        case .failure(let text):
            return text.promptRepresentation
        }
    }
}

extension ToolCallResult where Output == String {
    /// The output, or the failure text: the one `String` the model reads.
    var text: String {
        switch self {
        case .output(let text), .failure(let text):
            return text
        }
    }
}

extension ToolCallResult: InstructionsRepresentable, ConvertibleToGeneratedContent
where Output: ConvertibleToGeneratedContent {
    /// The tool's own generated content, or the failure text as generated
    /// content.
    var generatedContent: GeneratedContent {
        switch self {
        case .output(let output):
            return output.generatedContent
        case .failure(let text):
            return text.generatedContent
        }
    }
}
