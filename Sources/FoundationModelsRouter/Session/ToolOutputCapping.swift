import FoundationModels

/// Caps a tool's own output to ``TokenBudget/toolOutputLimit`` tokens before
/// the model — or the transcript's own recorded `.toolOutput` entry — ever
/// sees it (compaction_plan.md §1.7 seam 2, task 1334fk3).
///
/// Tool outputs, not prompts, are what blow a turn's context window
/// mid-turn, and Router's own tool-instancing pipeline
/// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)``/
/// ``RoutedSessionActor/fork(workingDirectory:)``) is the one seam that sees
/// every tool call's result before the model does — the same seam
/// ``ForkableTool`` already hooks into. This absorbs the
/// external per-tool capping wrapper job into that seam instead
/// of a wrapper consumers would otherwise have to maintain on their own.
enum ToolOutputCapping {
    /// Truncates `text` to at most `toTokenLimit` estimated tokens
    /// (``Compactor``'s own character-ratio estimate — compaction_plan.md
    /// §1.5 — since there is no live model to measure exactly against at
    /// this layer), appending an explicit truncation marker.
    ///
    /// Never silent: a caller (the model reading the returned text, or a
    /// driver watching ``SessionEvent/toolStatus(id:status:summary:)``,
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
        let kept = Self.prefix(of: text, keepingAtMostUTF8Bytes: keepBytes)
        return "\(kept)… [truncated: \(limit) of \(totalTokens) tokens]"
    }

    /// Returns the longest prefix of the given text whose UTF-8 encoding is
    /// at most `keepingAtMostUTF8Bytes` bytes — the same unit
    /// ``Compactor/estimatedTokenCount(of:)``
    /// measures the text's own total size in, so the kept prefix and the
    /// reported totals in ``capped(text:toTokenLimit:)``'s marker stay
    /// consistent with each other regardless of the text's script (ASCII,
    /// multi-byte UTF-8, or a mix).
    ///
    /// Always cuts on a `Character` (extended grapheme cluster) boundary —
    /// never mid-scalar or mid-emoji — by walking whole characters and
    /// stopping before the one that would exceed `keepingAtMostUTF8Bytes`.
    ///
    /// - Parameters:
    ///   - text: The text to take a prefix of.
    ///   - maxBytes: The maximum UTF-8 byte count the
    ///     returned prefix may have.
    /// - Returns: The longest valid `Character`-boundary prefix of the given
    ///   text whose UTF-8 encoding is at most `keepingAtMostUTF8Bytes`
    ///   bytes; empty when `keepingAtMostUTF8Bytes` is `0` or negative.
    private static func prefix(of text: String, keepingAtMostUTF8Bytes maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }

        var byteCount = 0
        var endIndex = text.startIndex
        for character in text {
            let characterByteCount = character.utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            byteCount += characterByteCount
            endIndex = text.index(after: endIndex)
        }
        return String(text[text.startIndex..<endIndex])
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
    /// seams need (``RoutedModel/makeSession(grammar:instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:)``
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
/// a ``DetachingTool`` wrapper) — this decorator is applied
/// outermost, so the model-facing tool the SDK actually calls is the capped
/// one: both continued generation and the transcript's own recorded
/// `.toolOutput` entry (and therefore
/// ``SessionEvent/toolStatus(id:status:summary:)``'s `summary`) see the
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
    /// One exemption: a rendered ``PendingRunEnvelope`` — the wire form an
    /// detached call returns in place of its output (task ^k4nygqa;
    /// capping wraps outside the detachment layer at every composition
    /// site) — passes through untouched. The envelope is control-plane
    /// data, not tool output: truncating it would destroy the
    /// `completionToken` the model needs to ever hear the parked run's
    /// completion again — and the `next` instruction that tells it to collect
    /// with that token instead of answering — so the exemption holds under
    /// any `limit`, however small. Recognition is the exact byte-shape check
    /// ``PendingRunEnvelope/isRendered(_:)``, so ordinary tool output can
    /// never ride through it.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to `wrapped`
    ///   untouched.
    /// - Returns: `wrapped`'s own output, capped to ``limit`` tokens — or
    ///   a rendered pending envelope, uncapped.
    /// - Throws: Whatever `wrapped.call(arguments:)` throws, unmodified.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        if PendingRunEnvelope.isRendered(output) {
            return output
        }
        return ToolOutputCapping.capped(text: output, toTokenLimit: limit)
    }
}

extension ToolDetachment {
    /// The per-tool session-mount composition every session tool-instancing
    /// site shares (task ^k4nygqa): detaches `tool` under the session's own
    /// identity, mailbox, and sink with
    /// ``DetachConfiguration/nativeSessionMount``, then — only when
    /// `cappedToTokenLimit` is set — caps the detached tool outermost via
    /// ``ToolOutputCapping/optionallyCapped(tool:toTokenLimit:)`` (task
    /// 1334fk3), so the SDK's own call reaches the capped decorator last
    /// and both continued generation and the recorded `.toolOutput` entry
    /// see the capped text. Capping outside detachment is safe: a rendered
    /// pending envelope is exempt from capping (see
    /// ``TokenCappingTool/call(arguments:)``), so the `completionToken`
    /// survives any configured limit.
    ///
    /// A non-String-output tool takes a narrower path through the same
    /// chain (task ^6htgvw2): ``ToolDetachment/wrapping(_:sessionID:mailbox:sink:configuration:)``
    /// mounts it in the binding-only ``ContextBindingTool`` — its ambient
    /// posts still carry the tool's own identity and a fresh per-call
    /// `correlationID` — and the capping layer passes it through unwrapped,
    /// since there is no `String` output to truncate.
    ///
    /// Shared by ``RoutedModel/makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)``
    /// (the root and restore sites) and
    /// ``RoutedSessionActor/fork(workingDirectory:)`` (which forks each
    /// tool first, then hands the forked copy here), so the detach → cap
    /// layering is stated exactly once.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount for one session.
    ///   - sessionID: The owning session's identity, stamped into each
    ///     detached run's ``ToolContext``.
    ///   - mailbox: The owning session's mailbox, where detached runs park.
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
            tool,
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            configuration: .nativeSessionMount
        )
        return ToolOutputCapping.optionallyCapped(tool: detached, toTokenLimit: tokenLimit)
    }
}
