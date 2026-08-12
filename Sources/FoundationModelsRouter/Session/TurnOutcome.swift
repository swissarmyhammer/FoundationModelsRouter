import Foundation

/// Everything one turn produced, folded from that turn's own
/// ``RoutedSession/streamEvents(to:maxTokens:)`` stream by
/// ``RoutedSession/respond(to:observing:)`` — the high-level entry point for a
/// caller that wants the reply text *plus* awareness of tools, folds, and
/// usage without re-implementing the ``SessionEvent`` switch (task ^1s8p8qt).
///
/// The fold this type is built by owns the subtle
/// ``SessionEvent/textReset`` accumulation rule through the shared
/// ``ResponseTextFold`` reducer, so ``reply`` is, character for character, the
/// string ``RoutedSession/respond(to:maxTokens:)`` returns for the same turn.
///
/// **Two tool views, two id spaces.** ``toolCalls`` is the post-turn diff's
/// view — each call's `id` is Apple's `Transcript.ToolCall.id`, with the
/// lifecycle its ``SessionEvent/toolStatus(id:status:summary:)`` events
/// reported. ``toolInvocations`` is the live view — each record's
/// ``ToolInvocationRecord/correlationID`` is the run's `completionToken`,
/// carrying the wall-clock open/close instants and the derived per-call
/// ``ToolInvocationRecord/duration``. Neither id ever appears in the other's
/// field; a consumer joins the two views explicitly (see
/// ``SessionEvent/toolInvocation(_:)`` for the identity rule).
public struct TurnOutcome: Sendable, Equatable {
    /// The turn's final reply text, with the ``SessionEvent/textReset`` rule
    /// applied — character-equal to what
    /// ``RoutedSession/respond(to:maxTokens:)`` returns for the same turn.
    public let reply: String

    /// The closing ``TokenUsage`` — the last ``SessionEvent/turnEnded(_:)``
    /// the turn emitted (a retried turn closes two attempts; this is the
    /// retry's), or `nil` when the backend reported no usage.
    public let usage: TokenUsage?

    /// The session's measured fill as the turn closed, or `nil` when the
    /// backend reported no usage — ``usage``'s own
    /// ``TokenUsage/contextFill``, surfaced for the caller that only wants
    /// the meter.
    public var contextFill: Double? {
        usage?.contextFill
    }

    /// Every ``CompactionResult`` the turn folded, in fold order — empty for
    /// a session vended without a budget, which never auto-compacts.
    public let compactions: [CompactionResult]

    /// The turn's tool invocations as the post-turn diff derived them, in
    /// diff order: id, name, arguments, and the lifecycle status/summary the
    /// turn's ``SessionEvent/toolStatus(id:status:summary:)`` events reported.
    public let toolCalls: [ToolCallEntry]

    /// The turn's live ``ToolInvocationRecord``s, in open order, one per run:
    /// the close record replaces its open record, so a completed run appears
    /// closed here with its ``ToolInvocationRecord/duration`` derivable. A
    /// run that detached past the turn's end keeps its open record.
    public let toolInvocations: [ToolInvocationRecord]
}

/// The internal reducer behind ``TurnOutcome``: applies one ``SessionEvent``
/// at a time and accumulates everything the outcome carries.
///
/// The response text folds through the shared ``ResponseTextFold``, the same
/// reducer ``SessionProjection`` splits its text rows with, so the
/// ``SessionEvent/textReset`` rule exists exactly once.
struct TurnOutcomeFold {
    /// The shared response-text reducer — the ``SessionEvent/textReset`` rule's
    /// one home.
    private var responseTextFold = ResponseTextFold()

    /// The most recent ``SessionEvent/turnEnded(_:)`` usage, or `nil` before
    /// one arrives.
    private var usage: TokenUsage?

    /// Every ``SessionEvent/compaction(_:)`` result so far, in fold order.
    private var compactions: [CompactionResult] = []

    /// The diff-derived tool calls so far, in diff order.
    private var toolCalls: [ToolCallEntry] = []

    /// The live invocation records so far, in open order — each run's latest
    /// record, maintained by ``applyToolInvocation(_:)``.
    private var toolInvocations: [ToolInvocationRecord] = []

    /// Where each run's record sits in ``toolInvocations``, keyed by
    /// ``ToolInvocationRecord/correlationID``, so a close record replaces its
    /// open record in place.
    private var invocationIndexByCorrelationID: [String: Int] = [:]

    /// Applies one ``SessionEvent`` to the accumulating outcome.
    ///
    /// - Parameter event: The event to apply.
    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .textDelta(let fragment):
            responseTextFold.append(fragment)
        case .textReset:
            responseTextFold.reset()
        case .toolCall(let id, let name, let argumentsJSON):
            toolCalls.append(
                ToolCallEntry(id: id, name: name, argumentsJSON: argumentsJSON, status: .running, summary: nil))
        case .toolStatus(let id, let status, let summary):
            updateToolCall(id: id, status: status, summary: summary)
        case .toolInvocation(let record):
            applyToolInvocation(record)
        case .compaction(let result):
            compactions.append(result)
        case .turnEnded(let attemptUsage):
            // Once per attempt, so a retried turn overwrites the failed
            // attempt's usage with the retry's — the closing value.
            usage = attemptUsage
        case .turnStarted, .reasoningDelta, .entryRecorded, .discoveryPrimingFailed:
            // Deliberately not carried by the outcome: the frame and the
            // priming report are live-driver concerns, reasoning is model
            // prose the reply excludes, and the recorded-entry closes exist
            // for consumers (like ``SessionProjection``) that key rows on
            // durable SDK entry ids. The `observing` callback still delivers
            // every one of them raw.
            break
        }
    }

    /// The outcome accumulated so far — complete once the turn's stream
    /// finished.
    var outcome: TurnOutcome {
        TurnOutcome(
            reply: responseTextFold.reply,
            usage: usage,
            compactions: compactions,
            toolCalls: toolCalls,
            toolInvocations: toolInvocations)
    }

    /// Updates the ``ToolCallEntry`` whose id matches `id` in place — a true
    /// no-op for a status with no preceding call, the same defensive posture
    /// ``SessionProjection`` takes for an untracked status.
    ///
    /// - Parameters:
    ///   - id: The originating call's `Transcript.ToolCall.id`.
    ///   - status: The invocation's current status.
    ///   - summary: The tool's output text once completed, or `nil`.
    private mutating func updateToolCall(id: String, status: ToolCallStatus, summary: String?) {
        guard let index = toolCalls.lastIndex(where: { $0.id == id }) else { return }
        toolCalls[index].status = status
        toolCalls[index].summary = summary
    }

    /// Tracks one live record: the first record of a run appends, and a later
    /// record for the same ``ToolInvocationRecord/correlationID`` — its close —
    /// replaces it in place, keeping open order and one record per run.
    ///
    /// - Parameter record: The record to track.
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
    /// Runs one turn and returns everything it produced — the high-level
    /// entry point that owns the event fold, so a caller gets the reply text
    /// plus tools, folds, and usage from one call (task ^1s8p8qt).
    ///
    /// A consumer of ``streamEvents(to:maxTokens:)`` — or a plain
    /// ``respond(to:maxTokens:)`` caller wanting more than the text — no
    /// longer writes the ``SessionEvent`` switch itself: this drives the turn
    /// through that same stream (it is a consumer, not a new turn mechanism)
    /// and folds every event through the shared reducers, including the
    /// subtle ``SessionEvent/textReset`` accumulation rule, so
    /// ``TurnOutcome/reply`` is character-equal to what
    /// ``respond(to:maxTokens:)`` returns for the same turn.
    ///
    /// The optional `observing` callback still delivers each raw
    /// ``SessionEvent`` live, in stream order and before it is folded, for a
    /// caller that wants both the fold and its own view of the stream —
    /// feeding a ``SessionProjection``, printing tool traffic, or watching
    /// ``SessionEvent/toolInvocation(_:)`` liveness.
    ///
    /// Cancelling the awaiting task abandons the stream behind this call,
    /// which cancels the turn and has it recorded as a cancelled turn,
    /// exactly as described on ``streamResponse(to:maxTokens:)``.
    ///
    /// The existing ``respond(to:)`` keeps returning `String`: a call
    /// without `observing` and without a `TurnOutcome` type context still
    /// resolves to that overload, so existing callers are unchanged.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - observing: A callback invoked with each raw ``SessionEvent`` as it
    ///     arrives, or `nil` (the default) to only fold.
    /// - Returns: The turn's ``TurnOutcome``.
    /// - Throws: Whatever the turn throws, after `observing` has seen every
    ///   event the turn yielded first.
    public func respond(
        to prompt: String,
        observing: (@Sendable (SessionEvent) -> Void)? = nil
    ) async throws -> TurnOutcome {
        var fold = TurnOutcomeFold()
        for try await event in streamEvents(to: prompt) {
            observing?(event)
            fold.apply(event)
        }
        return fold.outcome
    }
}
