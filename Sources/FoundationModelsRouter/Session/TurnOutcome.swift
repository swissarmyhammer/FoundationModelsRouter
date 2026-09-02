import Foundation

/// Everything one turn produced, folded from the turn's
/// ``RoutedSession/streamEvents(to:maxTokens:)`` stream by
/// ``RoutedSession/respond(to:maxTokens:observing:)``.
///
/// ``toolCalls`` is the post-turn diff's view, keyed by `Transcript.ToolCall.id`.
/// ``toolInvocations`` is the live view, keyed by the run's `completionToken`.
/// Neither id appears in the other's field.
public struct TurnOutcome: Sendable, Equatable {
    /// The turn's final reply text, with the ``SessionEvent/textReset`` rule applied.
    /// It is character-equal to what ``RoutedSession/respond(to:maxTokens:)`` returns.
    public let reply: String

    /// The closing ``TokenUsage`` from the last ``SessionEvent/turnEnded(_:)``,
    /// or `nil` when the backend reported no usage.
    public let usage: TokenUsage?

    /// The session's measured fill as the turn closed, or `nil` when the
    /// backend reported no usage.
    public var contextFill: Double? {
        usage?.contextFill
    }

    /// Every ``CompactionResult`` the turn folded, in fold order.
    public let compactions: [CompactionResult]

    /// The turn's tool invocations as the post-turn diff derived them, in diff order,
    /// with the lifecycle status the turn's ``SessionEvent/toolStatus(id:status:summary:output:)`` events reported.
    public let toolCalls: [ToolCallEntry]

    /// The turn's live ``ToolInvocationRecord``s, in open order, one per run.
    /// A close record replaces its open record. A run still in the background past the turn's end keeps its open record.
    public let toolInvocations: [ToolInvocationRecord]
}

/// The internal reducer behind ``TurnOutcome``: applies one ``SessionEvent``
/// at a time. The response text folds through the shared ``ResponseTextFold``,
/// so the ``SessionEvent/textReset`` rule exists exactly once.
struct TurnOutcomeFold {
    /// The shared response-text reducer.
    private var responseTextFold = ResponseTextFold()

    /// The most recent ``SessionEvent/turnEnded(_:)`` usage, or `nil`.
    private var usage: TokenUsage?

    /// Every ``SessionEvent/compaction(_:)`` result so far, in fold order.
    private var compactions: [CompactionResult] = []

    /// The diff-derived tool calls so far, in diff order.
    private var toolCalls: [ToolCallEntry] = []

    /// The live invocation records so far, in open order, one per run.
    private var toolInvocations: [ToolInvocationRecord] = []

    /// Where each run's record sits in ``toolInvocations``, keyed by correlation id.
    private var invocationIndexByCorrelationID: [String: Int] = [:]

    /// Applies one ``SessionEvent`` to the accumulating outcome.
    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .textDelta(let fragment):
            responseTextFold.append(fragment)
        case .textReset:
            responseTextFold.reset()
        case .toolCall(let id, let name, let argumentsJSON):
            toolCalls.append(
                ToolCallEntry(id: id, name: name, argumentsJSON: argumentsJSON, status: .running, summary: nil))
        case .toolStatus(let id, let status, let summary, let output):
            updateToolCall(id: id, status: status, summary: summary, output: output)
        case .toolInvocation(let record):
            applyToolInvocation(record)
        case .compaction(let result):
            compactions.append(result)
        case .turnEnded(let attemptUsage):
            // Once per attempt, so a retried turn overwrites the failed
            // attempt's usage with the retry's — the closing value.
            usage = attemptUsage
        case .turnStarted, .reasoningDelta, .entryRecorded, .discoveryPrimingFailed,
            .generationStalled, .runSettled, .toolCallReport:
            // Deliberately not carried by the outcome: the frame, the priming
            // report, the stall report, a background run's settlement, and a
            // call's attachments are live-driver concerns — a stall
            // report says the turn is still running and changes nothing about
            // what it finally produced, so it has no place in a finished
            // turn's outcome, and a tool call report carries records only a
            // host can decode. Reasoning is model prose the reply excludes, and
            // the recorded-entry closes exist for consumers (like
            // ``SessionProjection``) that key rows on durable SDK entry ids.
            // The `observing` callback still delivers every one of them raw.
            break
        }
    }

    /// The outcome accumulated so far. It is complete once the turn's stream finished.
    var outcome: TurnOutcome {
        TurnOutcome(
            reply: responseTextFold.reply,
            usage: usage,
            compactions: compactions,
            toolCalls: toolCalls,
            toolInvocations: toolInvocations)
    }

    /// Updates the ``ToolCallEntry`` whose id matches `id` in place.
    /// A status with no preceding call is a no-op.
    private mutating func updateToolCall(
        id: String, status: ToolCallStatus, summary: String?, output: [SegmentPayload]?
    ) {
        guard let index = toolCalls.lastIndex(where: { $0.id == id }) else { return }
        toolCalls[index].status = status
        toolCalls[index].summary = summary
        toolCalls[index].output = output
    }

    /// Tracks one live record. The first record of a run appends; a later
    /// record for the same correlation id replaces it in place.
    private mutating func applyToolInvocation(_ record: ToolInvocationRecord) {
        if let index = invocationIndexByCorrelationID[record.correlationID] {
            toolInvocations[index] = record
        } else {
            invocationIndexByCorrelationID[record.correlationID] = toolInvocations.count
            toolInvocations.append(record)
        }
    }
}

extension RoutedSession {
    /// Runs one turn through ``streamEvents(to:maxTokens:)`` and folds every
    /// event into a ``TurnOutcome``. Cancelling the awaiting task cancels the turn.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the model's default.
    ///   - observing: A callback that receives each raw ``SessionEvent`` before it is folded, or `nil`.
    /// - Returns: The turn's ``TurnOutcome``.
    /// - Throws: Whatever the turn throws, after `observing` has seen every event.
    public func respond(
        to prompt: String,
        maxTokens: Int? = nil,
        observing: (@Sendable (SessionEvent) -> Void)? = nil
    ) async throws -> TurnOutcome {
        var fold = TurnOutcomeFold()
        for try await event in streamEvents(to: prompt, maxTokens: maxTokens) {
            observing?(event)
            fold.apply(event)
        }
        return fold.outcome
    }
}
