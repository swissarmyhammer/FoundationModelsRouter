import FoundationModels

/// Caps a tool's own output to ``TokenBudget/toolOutputLimit`` tokens before
/// the model — or the transcript's own recorded `.toolOutput` entry — ever
/// sees it. Applied at the tool-instancing seam, so no consumer keeps its
/// own capping wrapper.
enum ToolOutputCapping {
    /// Truncates `text` to at most `toTokenLimit` estimated tokens
    /// (``Compactor``'s character-ratio estimate), appending an explicit
    /// truncation marker.
    ///
    /// Never silent: a caller (the model reading the returned text, or a
    /// driver watching ``SessionEvent/toolStatus(id:status:summary:output:)``,
    /// whose `summary` is exactly what the SDK recorded for this tool's
    /// return value) can always tell a result was capped, and by how much.
    ///
    /// - Parameters:
    ///   - text: The tool's raw output.
    ///   - limit: The maximum number of tokens to keep.
    /// - Returns: `text` unchanged when its estimated size is already at or
    ///   under `toTokenLimit` tokens; otherwise a truncated prefix
    ///   (approximately `toTokenLimit` tokens) followed by a
    ///   `"… [truncated: N of M tokens]"`
    ///   marker naming the kept limit (`N`) and the original estimated size
    ///   (`M`).
    static func capped(text: String, toTokenLimit limit: Int) -> String {
        let totalTokens = Compactor.estimatedTokenCount(of: text)
        guard totalTokens > limit else { return text }

        let keepBytes = max(0, Int((Double(limit) * Compactor.charsPerTokenEstimate).rounded(.down)))
        let kept = UTF8Budget.prefix(of: text, keepingAtMostBytes: keepBytes)
        return "\(kept)… [truncated: \(limit) of \(totalTokens) tokens]"
    }

    /// Wraps `tool` in a ``TokenCappingTool`` that caps its output to
    /// `toTokenLimit` tokens, discovered dynamically rather than requiring
    /// the tool to opt in — mirroring ``ForkableTool``'s own
    /// "no cooperation needed" contract.
    ///
    /// The check is a runtime existential cast against `Tool`'s own primary
    /// associated types (`any Tool<Arguments, Output>`): a tool whose
    /// `Output` is `String` casts successfully and gets wrapped; any other
    /// `Output` type passes `tool` through unchanged, since
    /// `FoundationModels.Prompt` — what every other `PromptRepresentable`
    /// ultimately becomes — exposes no generic way to recover and
    /// re-truncate its textual content.
    ///
    /// - Parameters:
    ///   - tool: The tool to consider for capping.
    ///   - limit: The token limit each call's output is capped to.
    /// - Returns: A capping decorator around `tool` when its `Output` is
    ///   `String`; `tool` itself otherwise.
    static func wrapping(tool: any Tool, toTokenLimit limit: Int) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let stringTool = tool as? any Tool<T.Arguments, String> else { return tool }
            return TokenCappingTool(wrapped: stringTool, limit: limit)
        }
        return open(tool)
    }

    /// Applies ``wrapping(tool:toTokenLimit:)`` only when a limit is actually
    /// configured — the shared guard-and-wrap both of Router's tool-instancing
    /// seams need (``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``
    /// for a root session, ``RoutedSessionActor/fork(workingDirectory:)`` for
    /// a forked one), so neither has to restate the nil-guard-and-wrap
    /// pattern itself.
    ///
    /// - Parameters:
    ///   - tool: The tool to consider for capping.
    ///   - limit: The token limit to cap to, or `nil` (e.g. no
    ///     ``TokenBudget`` configured, or a `TokenBudget` with no
    ///     ``TokenBudget/toolOutputLimit``) to leave `tool` uncapped.
    /// - Returns: `tool` unchanged when `toTokenLimit` is `nil`; otherwise
    ///   the result of ``wrapping(tool:toTokenLimit:)``.
    static func optionallyCapped(tool: any Tool, toTokenLimit limit: Int?) -> any Tool {
        guard let limit else { return tool }
        return wrapping(tool: tool, toTokenLimit: limit)
    }
}

/// A `Tool` decorator that caps a wrapped tool's `String` output to a fixed
/// token limit — see ``ToolOutputCapping`` for the truncation rule and why
/// this is discovered dynamically instead of requiring tool cooperation.
///
/// Forwards `name`/`description`/`parameters`/`includesSchemaInInstructions`
/// to `wrapped` untouched; only `call(arguments:)`'s return value is capped.
/// `wrapped` is whatever the tool-instancing pipeline already produced (e.g.
/// a ``RunToCompletionTool`` or ``BackgroundTool`` wrapper) — this decorator is applied
/// outermost, so the model-facing tool the SDK actually calls is the capped
/// one: both continued generation and the transcript's own recorded
/// `.toolOutput` entry (and therefore
/// ``SessionEvent/toolStatus(id:status:summary:output:)``'s `summary`) see the
/// capped text, never the oversized original.
struct TokenCappingTool<Arguments: ConvertibleFromGeneratedContent>: Tool {
    /// The wrapped tool, called through untouched save for its return value.
    let wrapped: any Tool<Arguments, String>

    /// The token limit ``call(arguments:)``'s return value is capped to.
    let limit: Int

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    /// Calls `wrapped`, then caps its result to ``limit`` tokens via
    /// ``ToolOutputCapping/capped(text:toTokenLimit:)``.
    ///
    /// One exemption: a rendered ``PendingRunEnvelope`` passes through
    /// untouched under any `limit`. It is control-plane data, and truncation
    /// would destroy the `completionToken` the model needs. Recognition is
    /// ``PendingRunEnvelope/isRendered(text:)``, which accepts no ordinary
    /// tool output.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to `wrapped`
    ///   untouched.
    /// - Returns: `wrapped`'s own output, capped to ``limit`` tokens — or
    ///   a rendered pending envelope, uncapped.
    /// - Throws: Whatever `wrapped.call(arguments:)` throws, unmodified.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        if PendingRunEnvelope.isRendered(text: output) {
            return output
        }
        return ToolOutputCapping.capped(text: output, toTokenLimit: limit)
    }
}

extension ToolDetachment {
    /// The per-tool session-mount composition every session tool-instancing
    /// site shares: mounts `tool` in the run-to-completion or background
    /// layer under the session's own identity, mailbox, and sink with
    /// ``DetachConfiguration/nativeSessionMount``, then — only when
    /// `cappedToTokenLimit` is set — caps the mounted tool outermost via
    /// ``ToolOutputCapping/optionallyCapped(tool:toTokenLimit:)``. A rendered
    /// pending envelope is exempt from capping (see
    /// ``TokenCappingTool/call(arguments:)``).
    ///
    /// The mount is the default for every tool: run to completion, bounded
    /// by ``DetachConfiguration/defaultTimeoutSeconds``, so a synchronous
    /// tool that hangs is reported as
    /// ``DetachingToolError/timedOut(tool:timeoutSeconds:)`` instead of
    /// holding the turn forever. No timer and no race decide whether a call
    /// goes to the background. A tool that is known ahead of time to run
    /// long — a shell tool, an agent tool — declares
    /// ``DetachConfiguration/Mode/background`` for itself through
    /// ``DetachmentParameterProviding/detachmentMount``, and that
    /// declaration wins over this mount. A file edit tool, a skill tool, and
    /// a discovery tool declare nothing and run in band. So this one site
    /// mounts both kinds, and the choice stays with the tool that knows.
    ///
    /// A non-String-output tool is mounted in the binding-only
    /// ``ContextBindingTool`` and passes the capping layer unwrapped, since
    /// there is no `String` output to truncate.
    ///
    /// Shared by ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
    /// (the root and restore sites) and
    /// ``RoutedSessionActor/fork(workingDirectory:)`` (which forks each
    /// tool first, then hands the forked copy here), so the mount → cap
    /// layering is stated exactly once.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount for one session.
    ///   - sessionID: The owning session's identity, stamped into each
    ///     detached run's ``ToolContext``.
    ///   - mailbox: The owning session's mailbox, which tracks the detached runs.
    ///   - sink: The upstream sink the run's events are posted to — the
    ///     session's own outbox.
    ///   - tokenLimit: The ``TokenBudget/toolOutputLimit`` to cap
    ///     rendered output to, or `nil` for no capping layer.
    /// - Returns: The composed, model-facing tool.
    static func sessionMounted(
        tool: any Tool,
        sessionID: ULID,
        mailbox: SessionMailbox,
        sink: any OperationEventSink,
        cappedToTokenLimit tokenLimit: Int?
    ) -> any Tool {
        let detached = wrapping(
            tool: tool,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            configuration: .nativeSessionMount
        )
        return ToolOutputCapping.optionallyCapped(tool: detached, toTokenLimit: tokenLimit)
    }
}
