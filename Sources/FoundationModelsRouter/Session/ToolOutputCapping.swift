import FoundationModels

/// Caps a tool's own output to ``TokenBudget/toolOutputLimit`` tokens before
/// the model — or the transcript's own recorded `.toolOutput` entry — ever
/// sees it (harness plan §5.1 seam 2, task 1334fk3).
///
/// Tool outputs, not prompts, are what blow a turn's context window
/// mid-turn, and Router's own tool-instancing pipeline
/// (``RoutedModel/makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)``/
/// ``RoutedSessionActor/fork(workingDirectory:)``) is the one seam that sees
/// every tool call's result before the model does — the same seam
/// ``EventEmittingTool``/``ForkableTool`` already hook into. This absorbs the
/// harness's own external `ObservedTool` capping job into that seam instead
/// of a wrapper the harness would otherwise have to maintain on its own.
enum ToolOutputCapping {
    /// Truncates `text` to at most `limit` estimated tokens
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
    ///   under `limit` tokens; otherwise a truncated prefix (approximately
    ///   `limit` tokens) followed by a `"… [truncated: N of M tokens]"`
    ///   marker naming the kept limit (`N`) and the original estimated size
    ///   (`M`).
    static func capped(_ text: String, toTokenLimit limit: Int) -> String {
        let totalTokens = Compactor.estimatedTokenCount(of: text)
        guard totalTokens > limit else { return text }

        let keepBytes = max(0, Int((Double(limit) * Compactor.charsPerTokenEstimate).rounded(.down)))
        let kept = Self.prefix(of: text, keepingAtMostUTF8Bytes: keepBytes)
        return "\(kept)… [truncated: \(limit) of \(totalTokens) tokens]"
    }

    /// Returns the longest prefix of `text` whose UTF-8 encoding is at most
    /// `maxBytes` bytes — the same unit ``Compactor/estimatedTokenCount(of:)``
    /// measures `text`'s own total size in, so the kept prefix and the
    /// reported totals in ``capped(_:toTokenLimit:)``'s marker stay
    /// consistent with each other regardless of `text`'s script (ASCII,
    /// multi-byte UTF-8, or a mix).
    ///
    /// Always cuts on a `Character` (extended grapheme cluster) boundary —
    /// never mid-scalar or mid-emoji — by walking whole characters and
    /// stopping before the one that would exceed `maxBytes`.
    ///
    /// - Parameters:
    ///   - text: The text to take a prefix of.
    ///   - maxBytes: The maximum UTF-8 byte count the returned prefix may
    ///     have.
    /// - Returns: The longest valid `Character`-boundary prefix of `text`
    ///   whose UTF-8 encoding is at most `maxBytes` bytes; empty when
    ///   `maxBytes` is `0` or negative.
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
    /// `limit` tokens, discovered dynamically rather than requiring the tool
    /// to opt in — mirroring ``EventEmittingTool``/``ForkableTool``'s own
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
    static func wrapping(_ tool: any Tool, toTokenLimit limit: Int) -> any Tool {
        func open<T: Tool>(_ tool: T) -> any Tool {
            guard let stringTool = tool as? any Tool<T.Arguments, String> else { return tool }
            return TokenCappingTool(wrapped: stringTool, limit: limit)
        }
        return open(tool)
    }
}

/// A `Tool` decorator that caps a wrapped tool's `String` output to a fixed
/// token limit — see ``ToolOutputCapping`` for the truncation rule and why
/// this is discovered dynamically instead of requiring tool cooperation.
///
/// Forwards `name`/`description`/`parameters`/`includesSchemaInInstructions`
/// to `wrapped` untouched; only `call(arguments:)`'s return value is capped.
/// `wrapped` is whatever the tool-instancing pipeline already produced (e.g.
/// an ``EventEmittingTool/connecting(_:)`` copy) — this decorator is applied
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
    /// ``ToolOutputCapping/capped(_:toTokenLimit:)``.
    ///
    /// - Parameter arguments: The call's arguments, forwarded to `wrapped`
    ///   untouched.
    /// - Returns: `wrapped`'s own output, capped to ``limit`` tokens.
    /// - Throws: Whatever `wrapped.call(arguments:)` throws, unmodified.
    func call(arguments: Arguments) async throws -> String {
        let output = try await wrapped.call(arguments: arguments)
        return ToolOutputCapping.capped(output, toTokenLimit: limit)
    }
}
