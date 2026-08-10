import Foundation

/// One element of the richer event stream ``RoutedSession/streamEvents(to:maxTokens:)``
/// produces — text/reasoning increments, tool-call lifecycle, and the turn's
/// own closing usage, all correlated by id where applicable.
///
/// The session event stream: this is
/// the general session-event vocabulary a driver — or ``SessionProjection``,
/// the `@Observable` per-session projection (task ekd82f4) — consumes
/// instead of a per-consumer type of its own. ``RoutedSession/streamEvents(to:maxTokens:)``
/// emits every case, including ``compaction(_:)`` — the auto-compaction
/// opt-in threaded through the same chokepoint (task 8213x39,
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
/// `budget:` parameter): a session with a budget set emits this whenever it
/// folds mid-turn on its own, proactively before a turn whose measured fill
/// has already reached the budget's trigger, or reactively after a turn
/// overflows and before the one retry. A session with no budget set never
/// emits it; ``RoutedSession/compact(prompt:budget:)`` — the explicit,
/// caller-driven fold — still returns its ``CompactionResult`` directly to
/// its own caller instead, exactly as before.
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

    /// An auto-compaction fold completed against this session, mid-turn. See
    /// this type's own documentation for when this is emitted.
    case compaction(CompactionResult)

    /// This turn's ``DiscoveryPriming`` could not seed, so the turn generated
    /// unseeded.
    ///
    /// Emitted only by a session that opted into priming
    /// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
    /// `discoveryPriming:` parameter), and only when its host-side discovery
    /// call did not produce a seed. It is a report, not a failure: the turn
    /// proceeds exactly as an unprimed one would, because priming improves a
    /// turn's opening move rather than being a precondition for having one. A
    /// session with priming off never emits it.
    ///
    /// Its payload is the ``DiscoveryPrimingFailure`` saying why the seed could
    /// not be built. Because priming runs on every turn, whichever entry point
    /// started it, this is emitted on two routes: a turn started by
    /// ``RoutedSession/streamEvents(to:maxTokens:)`` yields it on that turn's own
    /// stream, and *every* turn — including the ones
    /// ``RoutedSession/respond(to:maxTokens:)`` and
    /// ``RoutedSession/dispatchNextPrompt()`` run, which hand their caller a
    /// response rather than a stream — yields it on
    /// ``RoutedSession/streamSessionEvents()``.
    case discoveryPrimingFailed(DiscoveryPrimingFailure)

    /// One physical generate attempt closed, carrying its own measured token
    /// usage and the session's resulting ``RoutedSession/contextFill``.
    ///
    /// Emitted once per *inner* generate call, not once per logical turn
    /// (compaction_plan.md §1.7, task g2hcm36): a turn auto-compaction retries
    /// after a recovered overflow (``RoutedSession/compact(prompt:budget:)``'s
    /// documented reactive pattern, driven automatically when a budget is
    /// set) is two inner calls — the failed attempt and the retry — and each
    /// closes with its own ``turnEnded(_:)``, carrying the fill measured at
    /// that moment. This is what feeds a live context meter *during* a turn
    /// rather than only once the whole (possibly retried) turn finishes.
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

/// One generate attempt's own measured token usage — the `(input, output)`
/// delta ``RoutedSessionActor``'s chokepoint computes around it — plus the
/// session's resulting ``RoutedSession/contextFill``, wrapped for
/// ``SessionEvent/turnEnded(_:)``.
public struct TokenUsage: Sendable, Equatable {
    /// Input (prompt) tokens this attempt consumed.
    public let tokensIn: Int

    /// Output (completion) tokens this attempt produced.
    public let tokensOut: Int

    /// The session's measured ``RoutedSession/contextFill`` immediately after
    /// this attempt closed (compaction_plan.md §1.7, task g2hcm36) — the live
    /// context-meter value a driver reports mid-turn, not only once a whole
    /// (possibly retried) turn finishes. Unchanged from the prior attempt's
    /// value when this one never reached the backend (mirrors
    /// ``RoutedSession/contextFill``'s own "left untouched, not reset to a
    /// meaningless zero delta" rule).
    public let contextFill: Double

    /// Creates a token usage value.
    ///
    /// - Parameters:
    ///   - tokensIn: Input tokens this attempt consumed.
    ///   - tokensOut: Output tokens this attempt produced.
    ///   - contextFill: The session's measured ``RoutedSession/contextFill``
    ///     immediately after this attempt closed.
    public init(tokensIn: Int, tokensOut: Int, contextFill: Double) {
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.contextFill = contextFill
    }
}
