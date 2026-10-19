import FoundationModels
import FoundationModelsExtras
import FoundationModelsHooks

/// The tool hooks of one model call: the hooks of the session that makes the
/// call, and the way to find the SDK tool call of a tool body (task
/// ^8d73hct).
///
/// The session binds ``current`` for each model call, next to the no-op check
/// and the repetition check (``ModelCallToolChecks/bound(_:)``). Each tool
/// call of the model call then goes through these steps:
///
/// ```
/// pre PreToolUse -> tool body -> pre PreToolResult -> output to the model -> post PostToolUse
/// ```
///
/// A tool call outside a model call, where nothing is bound, runs no hook.
/// A dispatcher with no visitor runs no hook either.
struct ToolCallHooks: Sendable {
    /// The tool hooks of the model call that the current task runs in, or
    /// `nil` outside a model call.
    @TaskLocal static var current: ToolCallHooks?

    /// The hooks of the session that makes the model call.
    let hooks: SessionHooks

    /// Finds and claims the SDK tool call of a tool body that runs now, by
    /// the name of its tool (``RoutedSessionActor/claimHookedToolCall(named:)``).
    let claimToolCall: @Sendable (_ toolName: String) async -> Transcript.ToolCall?

    /// Runs one tool call through the tool hooks of the current model call.
    ///
    /// With no bound hooks, or with a dispatcher that has no visitor, `body`
    /// runs with `arguments`, and nothing else happens.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - arguments: The arguments that the model gave.
    ///   - form: How the output of the tool becomes text, and text becomes
    ///     an output.
    ///   - body: The tool body.
    /// - Returns: The output that the model gets.
    /// - Throws: What `body` throws.
    static func run<Arguments: ConvertibleFromGeneratedContent, Output>(
        toolName: String,
        arguments: Arguments,
        form: HookedOutputForm<Output>,
        body: (Arguments) async throws -> Output
    ) async throws -> Output {
        guard let current, !current.hooks.routerHooks.dispatcher.isEmpty else {
            return try await body(arguments)
        }
        let call = await current.identify(toolName: toolName, arguments: arguments)
        return try await current.run(call, arguments: arguments, form: form, body: body)
    }

    /// The identity of one tool call: its SDK id and the JSON text of the
    /// arguments that the model gave.
    ///
    /// The SDK tool call of the live transcript gives both, so the id is the
    /// id of the ``SessionEvent/toolCall(id:name:argumentsJSON:)`` event of
    /// the call. A call that the transcript does not show (a backend that
    /// calls a tool with no SDK tool call) gets a new id, and the arguments
    /// of the call give the JSON text.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool.
    ///   - arguments: The arguments that the model gave.
    /// - Returns: The identity of the call.
    private func identify<Arguments>(toolName: String, arguments: Arguments) async -> HookedToolCall {
        guard let toolCall = await claimToolCall(toolName) else {
            let content = (arguments as? any ConvertibleToGeneratedContent)?.generatedContent
            return HookedToolCall(
                id: ULID.generate().description, toolName: toolName,
                argumentsJSON: content?.jsonString ?? HookedToolCall.emptyArgumentsJSON)
        }
        return HookedToolCall(id: toolCall.id, toolName: toolName, argumentsJSON: toolCall.arguments.jsonString)
    }

    /// Runs one identified tool call through `PreToolUse`, the tool body,
    /// `PreToolResult` and `PostToolUse`.
    ///
    /// - Parameters:
    ///   - call: The identity of the call.
    ///   - arguments: The arguments that the model gave.
    ///   - form: How the output becomes text, and text becomes an output.
    ///   - body: The tool body.
    /// - Returns: The output that the model gets.
    /// - Throws: What `body` throws, after its `PostToolUse`.
    private func run<Arguments: ConvertibleFromGeneratedContent, Output>(
        _ call: HookedToolCall,
        arguments: Arguments,
        form: HookedOutputForm<Output>,
        body: (Arguments) async throws -> Output
    ) async throws -> Output {
        var call = call
        let admitted: Arguments
        switch await admit(&call, arguments: arguments) {
        case .refused(let text):
            post(call, output: text, succeeded: false)
            return form.replaced(text)
        case .admitted(let finalArguments):
            admitted = finalArguments
        }
        let output: Output
        do {
            output = try await body(admitted)
        } catch {
            post(call, output: String(describing: error), succeeded: false)
            throw error
        }
        return await screenResult(of: call, output: output, form: form)
    }

    /// What `PreToolUse` lets the tool body do.
    private enum Admission<Arguments> {
        /// The body runs with these arguments.
        case admitted(Arguments)
        /// The body does not run, and the model gets this text as the output.
        case refused(String)
    }

    /// Sends the `PreToolUse` of `call`, and acts on its outcome.
    ///
    /// A block refuses the call with its reason. A replaced `argumentsJSON`
    /// goes into `call` and decodes to the arguments of the body; when it does
    /// not decode, the decode error refuses the call. For now, an approval
    /// has the same effect as a proceed.
    ///
    /// - Parameters:
    ///   - call: The identity of the call. A replaced `argumentsJSON` goes
    ///     into it.
    ///   - arguments: The arguments that the model gave.
    /// - Returns: The arguments of the body, or the text of the refusal.
    private func admit<Arguments: ConvertibleFromGeneratedContent>(
        _ call: inout HookedToolCall, arguments: Arguments
    ) async -> Admission<Arguments> {
        let event = PreToolUse(toolCallID: call.id, toolName: call.toolName, argumentsJSON: call.argumentsJSON)
        switch await hooks.routerHooks.dispatcher.pre(event, session: hooks.session) {
        case .blocked(let reason):
            return .refused(reason)
        case .proceed(let final), .approved(let final):
            guard final.argumentsJSON != call.argumentsJSON else { return .admitted(arguments) }
            call.argumentsJSON = final.argumentsJSON
            do {
                return .admitted(try Arguments(GeneratedContent(json: final.argumentsJSON)))
            } catch {
                return .refused(String(describing: error))
            }
        }
    }

    /// Sends the `PreToolResult` and then the `PostToolUse` of a tool body
    /// that returned.
    ///
    /// A replaced `output` is what the model gets. A block gives the model
    /// its reason, and the `PostToolUse` then tells that the call did not
    /// succeed. With no change, the model gets `output` itself.
    ///
    /// - Parameters:
    ///   - call: The identity of the call.
    ///   - output: The output of the tool body.
    ///   - form: How the output becomes text, and text becomes an output.
    /// - Returns: The output that the model gets.
    private func screenResult<Output>(
        of call: HookedToolCall, output: Output, form: HookedOutputForm<Output>
    ) async -> Output {
        let text = form.text(output)
        let event = PreToolResult(
            toolCallID: call.id, toolName: call.toolName, argumentsJSON: call.argumentsJSON, output: text)
        switch await hooks.routerHooks.dispatcher.pre(event, session: hooks.session) {
        case .blocked(let reason):
            post(call, output: reason, succeeded: false)
            return form.replaced(reason)
        case .proceed(let final), .approved(let final):
            post(call, output: final.output, succeeded: true)
            return final.output == text ? output : form.replaced(final.output)
        }
    }

    /// Sends the `PostToolUse` of `call`.
    ///
    /// - Parameters:
    ///   - call: The identity of the call.
    ///   - output: The final output of the call, as text.
    ///   - succeeded: Whether the call succeeded.
    private func post(_ call: HookedToolCall, output: String, succeeded: Bool) {
        hooks.post(
            PostToolUse(
                toolCallID: call.id, toolName: call.toolName, argumentsJSON: call.argumentsJSON, output: output,
                succeeded: succeeded))
    }
}

/// The identity of one hooked tool call, as its tool events carry it.
private struct HookedToolCall {
    /// The JSON text of a call whose arguments give no JSON: an empty object.
    static let emptyArgumentsJSON = "{}"

    /// The SDK id of the call.
    let id: String

    /// The name of the tool.
    let toolName: String

    /// The arguments of the call, as JSON text. A replaced `argumentsJSON`
    /// of `PreToolUse` takes the place of the arguments that the model gave.
    var argumentsJSON: String
}

/// How the output of one tool becomes text for the tool events, and how a
/// text from a visitor becomes an output of that tool.
struct HookedOutputForm<Output> {
    /// The text of an output, as `PreToolResult` and `PostToolUse` carry it.
    let text: (Output) -> String

    /// The output that holds a text: a replaced output, a block reason, or a
    /// decode error.
    let replaced: (String) -> Output
}

extension HookedOutputForm where Output == String {
    /// The form of a `String` tool: the output is the text.
    static var text: HookedOutputForm<String> {
        HookedOutputForm(text: { $0 }, replaced: { $0 })
    }
}

/// The output of a hooked tool whose output is not `String`: the output of
/// the tool, or a text that a hook put in its place.
///
/// It gives the prompt and the generated content of the original output
/// unchanged, so the transcript records the same segment as with no hook.
/// It conforms to `ConvertibleToGeneratedContent` only when `Original` does,
/// so the transcript records a structure or text, the same as for the tool
/// beneath.
enum HookedToolOutput<Original: PromptRepresentable>: PromptRepresentable {
    /// The output of the tool.
    case original(Original)

    /// A text that a hook put in place of the output.
    case replaced(String)

    /// The prompt of the output, or the text.
    var promptRepresentation: Prompt {
        switch self {
        case .original(let output):
            output.promptRepresentation
        case .replaced(let text):
            text.promptRepresentation
        }
    }
}

extension HookedToolOutput: InstructionsRepresentable, ConvertibleToGeneratedContent
where Original: ConvertibleToGeneratedContent {
    /// The generated content of the output, or the text.
    var generatedContent: GeneratedContent {
        switch self {
        case .original(let output):
            output.generatedContent
        case .replaced(let text):
            text.generatedContent
        }
    }
}

/// The hook layer of a tool whose output is `String`.
///
/// It sits beneath the failure delivery of the tool list of the model (see
/// ``ToolCallHooking``), so a throw of the tool body reaches it, and a
/// replaced output is the text that the model and the transcript get.
struct HookedTextTool<Arguments: ConvertibleFromGeneratedContent>: Tool, SubmissionBoundaryTool, ToolDecorator {
    /// The tool beneath this decorator.
    let wrapped: any Tool<Arguments, String>

    /// The name of the wrapped tool.
    var name: String { wrapped.name }

    /// The description of the wrapped tool.
    var description: String { wrapped.description }

    /// The parameters of the wrapped tool.
    var parameters: GenerationSchema { wrapped.parameters }

    /// Whether the wrapped tool puts its schema in the instructions.
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Runs the wrapped tool through the tool hooks of the current model
    /// call (``ToolCallHooks/run(toolName:arguments:form:body:)``).
    ///
    /// - Parameter arguments: The arguments that the model gave.
    /// - Returns: The output that the model gets.
    /// - Throws: What the wrapped tool throws.
    func call(arguments: Arguments) async throws -> String {
        try await ToolCallHooks.run(toolName: name, arguments: arguments, form: .text) {
            try await wrapped.call(arguments: $0)
        }
    }
}

/// The hook layer of a tool whose output is not `String`.
///
/// It sits beneath the failure delivery of the tool list of the model (see
/// ``ToolCallHooking``). Its output is a ``HookedToolOutput``, which holds
/// the output of the wrapped tool or a text that a hook put in its place.
struct HookedResultTool<Wrapped: Tool>: Tool, SubmissionBoundaryTool, ToolDecorator {
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

    /// Runs the wrapped tool through the tool hooks of the current model
    /// call (``ToolCallHooks/run(toolName:arguments:form:body:)``).
    ///
    /// The text of an output is the text that the transcript records for it
    /// (`ToolResultAppend`): the JSON text of its generated content, or the
    /// text of its prompt.
    ///
    /// - Parameter arguments: The arguments that the model gave.
    /// - Returns: The output that the model gets.
    /// - Throws: What the wrapped tool throws.
    func call(arguments: Wrapped.Arguments) async throws -> HookedToolOutput<Wrapped.Output> {
        let form = HookedOutputForm<HookedToolOutput<Wrapped.Output>>(
            text: { [name] in ToolResultAppend(toolName: name, arguments: arguments, result: $0).text },
            replaced: { .replaced($0) })
        return try await ToolCallHooks.run(toolName: name, arguments: arguments, form: form) {
            .original(try await wrapped.call(arguments: $0))
        }
    }
}

/// Puts the hook layer on each tool of the tool list of the model
/// (``Tool/sessionChecked``).
///
/// The failure delivery of FoundationModelsExtras is the outermost layer of a
/// mounted tool: it gives a failure to the model as the output of the call,
/// so a throw of the tool body never leaves it. The tool events must see that
/// throw (`PostToolUse` with `succeeded: false`). Thus the hook layer goes
/// beneath the failure delivery: on the tool that still throws, with a new
/// failure delivery over it. The failure delivery then gives the final
/// output, after a hook replaced it, to the tool-result append boundary.
enum ToolCallHooking {
    /// `tool` with the hook layer beneath its failure delivery, or with the
    /// hook layer on top when it has no failure delivery.
    ///
    /// `ToolFailureDelivery.throwingTool(of:)` gives the tool itself when it
    /// has no failure delivery, so a tool of the same type tells that there
    /// is no failure delivery to keep.
    ///
    /// - Parameter tool: A tool of the tool list of the model.
    /// - Returns: The hooked tool, with the same layers above the tool body.
    static func hooked<Mounted: Tool>(_ tool: Mounted) -> any Tool {
        let throwing = ToolFailureDelivery.throwingTool(of: tool)
        let hooked = hookLayer(over: throwing)
        guard ObjectIdentifier(type(of: throwing)) != ObjectIdentifier(Mounted.self) else { return hooked }
        return ToolFailureDelivery.makeWrapped(tool: hooked)
    }

    /// The hook layer that fits the output of `tool`: ``HookedTextTool`` for
    /// a `String` output, else ``HookedResultTool``.
    ///
    /// - Parameter tool: The tool that throws its failures.
    /// - Returns: The hook layer over `tool`.
    private static func hookLayer<Body: Tool>(over tool: Body) -> any Tool {
        guard let textTool = tool as? any Tool<Body.Arguments, String> else {
            return HookedResultTool(wrapped: tool)
        }
        return HookedTextTool(wrapped: textTool)
    }
}
