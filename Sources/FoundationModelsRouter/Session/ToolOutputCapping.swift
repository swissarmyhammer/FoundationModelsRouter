import FoundationModels
import Tracing

/// Caps a tool's own output to ``TokenBudget/toolOutputLimit`` tokens before
/// the model — or the transcript's own recorded `.toolOutput` entry — ever
/// sees it. Applied at the tool-instancing seam, so no consumer keeps its
/// own capping wrapper.
enum ToolOutputCapping {
    /// Truncates `text` to `limit` tokens, counted by `counter`: the text is
    /// encoded, the first `limit` tokens are kept, and they are decoded back.
    ///
    /// Never silent: the truncation marker tells a caller that the result was
    /// capped, and states the kept and the original token counts.
    ///
    /// - Parameters:
    ///   - text: The tool output to cap.
    ///   - limit: The tokens the result may hold.
    ///   - counter: The session's counter.
    /// - Returns: `text` when it holds at most `limit` tokens, else the kept
    ///   prefix with the marker.
    static func capped(text: String, toTokenLimit limit: Int, counter: any TokenCounter) -> String {
        let totalTokens = counter.count(text)
        guard totalTokens > limit else { return text }

        let kept = counter.prefix(of: text, tokens: limit)
        return "\(kept)… [truncated: \(limit) of \(totalTokens) tokens]"
    }

    /// Wraps `tool` in a ``TokenCappingTool``, discovered dynamically rather
    /// than requiring the tool to opt in — the same "no cooperation needed"
    /// contract ``ForkableTool`` has.
    ///
    /// The check is a runtime existential cast against `Tool`'s own primary
    /// associated types (`any Tool<Arguments, Output>`). A tool whose `Output`
    /// is `String` is wrapped; any other `Output` passes through unchanged,
    /// because `FoundationModels.Prompt` — what every other
    /// `PromptRepresentable` ultimately becomes — exposes no generic way to
    /// recover and re-truncate its textual content.
    ///
    /// - Parameters:
    ///   - tool: The tool to wrap.
    ///   - limit: The tokens each call's result may hold.
    ///   - counter: The session's counter.
    /// - Returns: The capping wrapper, or `tool` unchanged.
    static func makeWrapped(tool: any Tool, toTokenLimit limit: Int, counter: any TokenCounter) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let stringTool = tool as? any Tool<T.Arguments, String> else { return tool }
            return TokenCappingTool(wrapped: stringTool, limit: limit, counter: counter)
        }
        return open(tool)
    }

    /// Applies ``makeWrapped(tool:toTokenLimit:counter:)`` only when a limit is
    /// configured. Both of Router's tool-instancing seams need this
    /// guard-and-wrap, so neither restates it.
    ///
    /// - Parameters:
    ///   - tool: The tool to wrap.
    ///   - limit: The tokens each call's result may hold, or `nil` for no cap.
    ///   - counter: The session's counter.
    /// - Returns: The capping wrapper, or `tool` unchanged.
    static func optionallyCapped(tool: any Tool, toTokenLimit limit: Int?, counter: any TokenCounter) -> any Tool {
        guard let limit else { return tool }
        return makeWrapped(tool: tool, toTokenLimit: limit, counter: counter)
    }
}

/// A `Tool` decorator that caps a wrapped tool's `String` output — see
/// ``ToolOutputCapping`` for the truncation rule and for why capping is
/// discovered dynamically instead of requiring tool cooperation.
///
/// Applied over whatever the tool-instancing pipeline already
/// produced (a ``RunToCompletionRunner`` or ``BackgroundToolRunner`` wrapper),
/// beneath only the ``ToolFailureDelivery`` decorator, which adds no text to
/// a successful output,
/// so the model-facing tool the SDK actually calls is the capped one: both
/// continued generation and the transcript's own recorded `.toolOutput` entry
/// — and therefore ``SessionEvent/toolStatus(id:status:summary:output:)``'s
/// `summary` — see the capped text, never the oversized original.
struct TokenCappingTool<
    Arguments: ConvertibleFromGeneratedContent
>: Tool, SubmissionBoundaryTool, ToolDecorator {
    let wrapped: any Tool<Arguments, String>

    /// The tokens each call's result may hold.
    let limit: Int

    /// The counter that counts the result, the owning session's own.
    let counter: any TokenCounter

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Calls `wrapped` and caps its result to ``limit`` tokens.
    ///
    /// A rendered ``PendingRunEnvelope`` is treated as what it is:
    /// control-plane data. A truncated envelope would lose the
    /// `completionToken` the model needs, so the frame is never cut.
    /// Recognition is ``PendingRunEnvelope/decoded(fromRendered:)``, which
    /// accepts no ordinary tool output.
    ///
    /// An envelope that carries a settled run's result is still capped, but
    /// only in its `detail` field. The result there is as big as any other
    /// tool output, and the same `limit` must hold for it. The control fields
    /// around it stay whole.
    ///
    /// - Throws: Whatever `wrapped` throws, unmodified. This decorator wraps
    ///   the output, never the error.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        guard let envelope = PendingRunEnvelope.decoded(fromRendered: output) else {
            return ToolOutputCapping.capped(text: output, toTokenLimit: limit, counter: counter)
        }
        guard let detail = envelope.detail else {
            return output
        }
        let cappedDetail = ToolOutputCapping.capped(text: detail, toTokenLimit: limit, counter: counter)
        return envelope.replacing(detail: cappedDetail).rendered
    }
}

extension ToolMounting {
    /// The per-tool session-mount composition every session tool-instancing
    /// site shares.
    ///
    /// The mount is the default for every tool: run to completion with no
    /// timeout. A tool has a timeout only when the tool's own declaration
    /// states one, through ``BackgroundTool/mount`` or
    /// ``BackgroundTool/timeout(from:)``. No timer and no race decide whether a call
    /// goes to the background. A tool known ahead of time to run long declares
    /// ``ToolMount/Mode/background`` for itself through ``BackgroundTool/mount``,
    /// and that declaration wins over the ``ToolMount/synchronous`` passed
    /// here. So this one site mounts both kinds, and the choice stays with the
    /// tool that knows.
    ///
    /// A non-`String`-output tool is mounted in the binding-only
    /// ``ContextBindingTool``.
    ///
    /// The outermost layer is the ``ToolFailureDelivery`` decorator, over the
    /// capping layer. This list is what the model calls, so a failed call is a
    /// tool result that the model reads, and only a cancellation throws. A
    /// caller that is not the model reaches the layer beneath through
    /// ``ToolFailureDelivery/throwingTool(of:)``.
    ///
    /// Every argument must be the owning session's own: `sessionID` is stamped
    /// into each background run's ``ToolContext``, `mailbox` tracks the
    /// background runs, `sink` is the session's outbox, which receives
    /// their events, and `tokenCounter` counts each capped result the way the
    /// session's model counts it.
    ///
    /// ``RoutedSessionActor/fork(workingDirectory:)`` forks each tool first and
    /// hands the forked copy here;
    /// ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:tokenCounter:)``
    /// is the root and restore site.
    ///
    /// - Parameter tracer: The owning session's tracer, which the mounted
    ///   decorator opens each call's span through, or `nil` to read
    ///   `InstrumentationSystem.tracer` at call time. The capping layer opens no
    ///   span of its own — see ``ToolCallSpan``.
    static func makeSessionMounted(
        tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        cappedToTokenLimit tokenLimit: Int?,
        tokenCounter: any TokenCounter,
        tracer: (any Tracer)? = nil
    ) -> any Tool {
        let mounted = makeWrapped(
            tool: tool,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            configuration: .synchronous,
            tracer: tracer
        )
        let capped = ToolOutputCapping.optionallyCapped(tool: mounted, toTokenLimit: tokenLimit, counter: tokenCounter)
        return ToolFailureDelivery.makeWrapped(tool: capped)
    }
}
