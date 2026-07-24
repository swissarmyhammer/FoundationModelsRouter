import Foundation

/// One element of the richer event stream ``RoutedSession/streamEvents(to:maxTokens:)``
/// produces — text/reasoning increments, tool-call lifecycle, and the turn's
/// own closing usage, all correlated by id where applicable.
///
/// Harness-collapse item (harness plan §4, `HarnessEvent` absorbed): this is
/// the general session-event vocabulary a driver — or a future `@Observable`
/// per-session projection (task ekd82f4) — consumes instead of a
/// harness-specific type of its own. ``RoutedSession/streamEvents(to:maxTokens:)``
/// emits every case but ``compaction(_:)``: that case is reserved for the
/// auto-compaction opt-in threaded through the same chokepoint (task
/// 8213x39, not yet built), which will fold mid-turn and needs a way to
/// report it through this same stream; ``RoutedSession/compact(prompt:budget:)``
/// still returns its ``CompactionResult`` directly to its own caller today.
public enum SessionEvent: Sendable, Equatable {
    /// A fragment of the model's response text, in production order — the
    /// same fragments ``RoutedSession/streamResponse(to:maxTokens:)`` yields.
    case textDelta(String)

    /// A fragment of the model's reasoning trace, present only when the
    /// backend recorded a `.reasoning` transcript entry for this turn.
    case reasoningDelta(String)

    /// A tool invocation the model requested, mirroring one
    /// ``ToolCallPayload`` off the SDK's own `.toolCalls` transcript entry.
    ///
    /// - Parameters:
    ///   - id: The invocation's own id — Apple's `Transcript.ToolCall.id`,
    ///     stable across this call's ``toolStatus(id:status:summary:)``
    ///     updates and load-bearing for distinguishing two concurrent
    ///     same-name tool calls.
    ///   - name: The tool's name.
    ///   - argumentsJSON: The call's arguments, as `GeneratedContent.jsonString`.
    case toolCall(id: String, name: String, argumentsJSON: String)

    /// A lifecycle update for a tool invocation previously announced by
    /// ``toolCall(id:name:argumentsJSON:)``, correlated by `id`.
    ///
    /// - Parameters:
    ///   - id: The originating call's id.
    ///   - status: The invocation's current status.
    ///   - summary: The tool's output text once ``ToolCallStatus/completed``,
    ///     or `nil` for ``ToolCallStatus/running``/``ToolCallStatus/failed``.
    case toolStatus(id: String, status: ToolCallStatus, summary: String?)

    /// A compaction fold completed against this session. See this type's own
    /// documentation for why nothing currently emits this case.
    case compaction(CompactionResult)

    /// The turn closed, carrying its own measured token usage.
    case turnEnded(TokenUsage)
}

/// The lifecycle of one tool invocation a model requested, as observed
/// through the SDK's own transcript.
public enum ToolCallStatus: String, Sendable, Equatable, Codable {
    /// The model requested the call and it was dispatched to the tool — the
    /// SDK recorded a `.toolCalls` entry naming it.
    case running

    /// The tool returned output — the SDK recorded a matching `.toolOutput`
    /// entry, correlated by id.
    case completed

    /// The turn ended with no matching `.toolOutput` ever recorded for this
    /// call — the tool errored, or the turn was aborted before the SDK
    /// recorded its result.
    case failed
}

/// A turn's own measured token usage — the `(input, output)` delta
/// ``RoutedSessionActor``'s chokepoint computes around one turn, wrapped for
/// ``SessionEvent/turnEnded(_:)``.
public struct TokenUsage: Sendable, Equatable {
    /// Input (prompt) tokens this turn consumed.
    public let tokensIn: Int

    /// Output (completion) tokens this turn produced.
    public let tokensOut: Int

    /// Creates a token usage value.
    ///
    /// - Parameters:
    ///   - tokensIn: Input tokens this turn consumed.
    ///   - tokensOut: Output tokens this turn produced.
    public init(tokensIn: Int, tokensOut: Int) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
    }
}
