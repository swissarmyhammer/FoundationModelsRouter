import Foundation
import FoundationModels
import FoundationModelsExtras
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
/// produced (the run-to-completion or background runner of the Extras tool
/// hosting), beneath only the failure-delivery decorator of
/// `ToolFailureDelivery`, which adds no text to a successful output,
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
    /// Recognition is `PendingRunEnvelope.makeDecoded(fromRendered:)`, which
    /// accepts no ordinary tool output.
    ///
    /// Each other output is capped. That includes the own output of a
    /// background run that ends inside its settle period, because that run
    /// answers with its result and not with an envelope.
    ///
    /// - Throws: Whatever `wrapped` throws, unmodified. This decorator wraps
    ///   the output, never the error.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        guard PendingRunEnvelope.makeDecoded(fromRendered: output) == nil else {
            return output
        }
        return ToolOutputCapping.capped(text: output, toTokenLimit: limit, counter: counter)
    }
}

extension ToolMounting {
    /// The per-tool session-mount composition every session tool-instancing
    /// site shares.
    ///
    /// The tool hosting of FoundationModelsExtras mounts the tool. The mount
    /// is the default for every tool: run to completion with no timeout. A
    /// tool has a timeout only when the tool's own declaration states one,
    /// through `BackgroundTool.mount` or `BackgroundTool.timeout(from:)`.
    /// No timer and no race decide whether a call goes to the background. A
    /// tool known ahead of time to run long declares
    /// `ToolMount.Mode.background` for itself through
    /// `BackgroundTool.mount` or `BackgroundTool.mount(for:)`, and that
    /// declaration wins over the `ToolMount.synchronous` passed here. So
    /// this one site mounts both kinds, and the choice stays with the tool
    /// that knows.
    ///
    /// The Extras tool hosting mounts a non-`String`-output tool in a
    /// binding-only decorator: the decorator binds the ambient
    /// ``ToolContext`` and does not cap or background the call.
    ///
    /// The outermost layer is the failure-delivery decorator of
    /// `ToolFailureDelivery`, over the capping layer. This list is what the
    /// model calls, so a failed call is a tool result that the model reads,
    /// and only a cancellation throws. A caller that is not the model
    /// reaches the layer beneath through `ToolFailureDelivery.throwingTool(of:)`.
    ///
    /// Every argument must be the owning session's own: `sessionID` is stamped
    /// into each background run's ``ToolContext``, `mailbox` tracks the
    /// background runs, `sink` is the session's outbox, which receives
    /// their events, and `tokenCounter` counts each capped result the way the
    /// session's model counts it.
    ///
    /// ``RoutedSessionActor/fork(workingDirectory:)`` forks each tool first and
    /// hands the forked copy here;
    /// ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:tokenCounter:inlineSettleGrace:)``
    /// is the root and restore site.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - sessionID: The identity of the owning session.
    ///   - mailbox: The run plane of the owning session.
    ///   - sink: The event sink of the owning session, its outbox.
    ///   - tokenLimit: The tokens each call's result may hold, or `nil` for
    ///     no cap.
    ///   - tokenCounter: The counter of the owning session.
    ///   - tracer: The owning session's tracer, which the mounted
    ///     decorator opens each call's span through, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time. The capping layer
    ///     opens no span of its own: the Extras mount layer opens the one
    ///     span of each call.
    ///   - inlineSettleGrace: How long each background call waits for its own
    ///     run, in seconds. See ``SessionConfiguration/inlineSettleGrace``.
    ///     A negative value acts as `0`.
    /// - Returns: The model-facing tool.
    static func makeSessionMounted(
        tool: any Tool,
        sessionID: ULID,
        mailbox: RunPlane,
        sink: any OperationEventSink,
        cappedToTokenLimit tokenLimit: Int?,
        tokenCounter: any TokenCounter,
        tracer: (any Tracer)? = nil,
        inlineSettleGrace: TimeInterval
    ) -> any Tool {
        let mounted = makeWrapped(
            tool: tool,
            site: MountSite(
                sessionID: sessionID, runPlane: mailbox, sink: sink, tracer: tracer,
                inlineSettleGrace: inlineSettleGrace),
            configuration: .synchronous
        )
        let capped = ToolOutputCapping.optionallyCapped(tool: mounted, toTokenLimit: tokenLimit, counter: tokenCounter)
        return ToolFailureDelivery.makeWrapped(tool: capped)
    }
}
