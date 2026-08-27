import FoundationModels

/// Caps a tool's own output to ``TokenBudget/toolOutputLimit`` tokens before
/// the model — or the transcript's own recorded `.toolOutput` entry — ever
/// sees it. Applied at the tool-instancing seam, so no consumer keeps its
/// own capping wrapper.
enum ToolOutputCapping {
    /// Truncates `text` to an estimated `limit` tokens. The size is
    /// ``Compactor``'s character-ratio estimate, not an exact count.
    ///
    /// Never silent: the truncation marker tells a caller that the result was
    /// capped, and by how much.
    static func capped(text: String, toTokenLimit limit: Int) -> String {
        let totalTokens = Compactor.estimatedTokenCount(of: text)
        guard totalTokens > limit else { return text }

        let keepBytes = max(0, Int((Double(limit) * Compactor.charsPerTokenEstimate).rounded(.down)))
        let kept = UTF8Budget.prefix(of: text, keepingAtMostBytes: keepBytes)
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
    static func makeWrapped(tool: any Tool, toTokenLimit limit: Int) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let stringTool = tool as? any Tool<T.Arguments, String> else { return tool }
            return TokenCappingTool(wrapped: stringTool, limit: limit)
        }
        return open(tool)
    }

    /// Applies ``makeWrapped(tool:toTokenLimit:)`` only when a limit is
    /// configured. Both of Router's tool-instancing seams need this
    /// guard-and-wrap, so neither restates it.
    static func optionallyCapped(tool: any Tool, toTokenLimit limit: Int?) -> any Tool {
        guard let limit else { return tool }
        return makeWrapped(tool: tool, toTokenLimit: limit)
    }
}

/// A `Tool` decorator that caps a wrapped tool's `String` output — see
/// ``ToolOutputCapping`` for the truncation rule and for why capping is
/// discovered dynamically instead of requiring tool cooperation.
///
/// Applied outermost over whatever the tool-instancing pipeline already
/// produced (a ``RunToCompletionRunner`` or ``BackgroundToolRunner`` wrapper),
/// so the model-facing tool the SDK actually calls is the capped one: both
/// continued generation and the transcript's own recorded `.toolOutput` entry
/// — and therefore ``SessionEvent/toolStatus(id:status:summary:output:)``'s
/// `summary` — see the capped text, never the oversized original.
struct TokenCappingTool<
    Arguments: ConvertibleFromGeneratedContent
>: Tool, TurnBoundaryTool, ToolDecorator {
    let wrapped: any Tool<Arguments, String>

    let limit: Int

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Calls `wrapped` and caps its result to ``limit`` tokens.
    ///
    /// One exemption: a rendered ``PendingRunEnvelope`` passes through
    /// untouched under any `limit`. It is control-plane data, and truncation
    /// would destroy the `completionToken` the model needs. Recognition is
    /// ``PendingRunEnvelope/isRendered(text:)``, which accepts no ordinary
    /// tool output.
    ///
    /// - Throws: Whatever `wrapped` throws, unmodified. This decorator wraps
    ///   the output, never the error.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        if PendingRunEnvelope.isRendered(text: output) {
            return output
        }
        return ToolOutputCapping.capped(text: output, toTokenLimit: limit)
    }
}

extension ToolMounting {
    /// The per-tool session-mount composition every session tool-instancing
    /// site shares.
    ///
    /// The mount is the default for every tool: run to completion, bounded by
    /// ``ToolMount/defaultTimeoutSeconds``, so a synchronous tool that hangs is
    /// reported as ``ToolMountError/timedOut(tool:timeoutSeconds:)`` instead of
    /// holding the turn forever. No timer and no race decide whether a call
    /// goes to the background. A tool known ahead of time to run long declares
    /// ``ToolMount/Mode/background`` for itself through ``BackgroundTool/mount``,
    /// and that declaration wins over the ``ToolMount/synchronous`` passed
    /// here. So this one site mounts both kinds, and the choice stays with the
    /// tool that knows.
    ///
    /// A non-`String`-output tool is mounted in the binding-only
    /// ``ContextBindingTool``.
    ///
    /// Every argument must be the owning session's own: `sessionID` is stamped
    /// into each background run's ``ToolContext``, `mailbox` tracks the
    /// background runs, and `sink` is the session's outbox, which receives
    /// their events.
    ///
    /// ``RoutedSessionActor/fork(workingDirectory:)`` forks each tool first and
    /// hands the forked copy here;
    /// ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
    /// is the root and restore site.
    static func makeSessionMounted(
        tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        cappedToTokenLimit tokenLimit: Int?
    ) -> any Tool {
        let mounted = makeWrapped(
            tool: tool,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            configuration: .synchronous
        )
        return ToolOutputCapping.optionallyCapped(tool: mounted, toTokenLimit: tokenLimit)
    }
}
