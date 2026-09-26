import Foundation

/// The final answer of one chain of submissions: everything the chain
/// produced for the messages it delivered (`generation-queue.md`, section
/// 5.6).
///
/// Carried by ``SessionEvent/answered(_:)``, one time for each final answer,
/// and returned by ``RoutedSession/respond(to:maxTokens:observing:)``. A chain
/// is the first submission that delivered the messages and each continuation
/// of it.
///
/// ``toolCalls`` is the view of the recorded transcript, keyed by
/// `Transcript.ToolCall.id`. ``toolInvocations`` is the live view, keyed by
/// the run's `completionToken`. Neither id appears in the other's field.
public struct SessionAnswer: Sendable, Equatable {
    /// The final reply of the chain: the reply of its last submission. It is
    /// character-equal to what ``RoutedSession/respond(to:maxTokens:)``
    /// returns for the same message.
    public let reply: String

    /// Every caller message this answer answers, in the order the chain
    /// delivered them. A message that joined a continuation of the chain is
    /// in it too. Empty for an answer to mail alone.
    public let messageIds: [MessageID]

    /// The token usage of the chain: ``TokenUsage/tokensIn`` and
    /// ``TokenUsage/tokensOut`` are the sums over each
    /// ``SessionEvent/submissionEnded(_:)`` of the chain that carried usage,
    /// and ``TokenUsage/contextFill`` and ``TokenUsage/finishReason`` come
    /// from the last of them. `nil` when no submission of the chain carried
    /// usage.
    public let usage: TokenUsage?

    /// The session's measured fill as the chain ended, or `nil` when the
    /// backend reported no usage.
    public var contextFill: Double? {
        usage?.contextFill
    }

    /// Every ``CompactionResult`` of the chain, in compaction order.
    public let compactions: [CompactionResult]

    /// The tool invocations of the chain as the recorded transcript names
    /// them, in record order, with the lifecycle status that the
    /// ``SessionEvent/toolStatus(id:status:summary:output:)`` events reported.
    public let toolCalls: [ToolCallEntry]

    /// The live ``ToolInvocationRecord``s of the chain, in open order, one for
    /// each run. A close record replaces its open record. A run that still
    /// runs in the background after the chain ended keeps its open record.
    public let toolInvocations: [ToolInvocationRecord]

    /// Creates an answer.
    ///
    /// The session makes one for each final answer. A consumer can make one
    /// again, for example for a fake event stream in its own tests.
    ///
    /// - Parameters:
    ///   - reply: The final reply of the chain.
    ///   - messageIds: The caller messages the answer answers.
    ///   - usage: The token usage of the chain, or `nil`.
    ///   - compactions: The compactions of the chain, in order.
    ///   - toolCalls: The recorded tool calls of the chain, in order.
    ///   - toolInvocations: The live invocation records of the chain, in open
    ///     order.
    public init(
        reply: String,
        messageIds: [MessageID],
        usage: TokenUsage?,
        compactions: [CompactionResult],
        toolCalls: [ToolCallEntry],
        toolInvocations: [ToolInvocationRecord]
    ) {
        self.reply = reply
        self.messageIds = messageIds
        self.usage = usage
        self.compactions = compactions
        self.toolCalls = toolCalls
        self.toolInvocations = toolInvocations
    }
}

/// The end of a chain of submissions that gave no answer.
///
/// Carried by ``SessionEvent/answerFailed(_:)``, in place of
/// ``SessionEvent/answered(_:)``. The callers of the messages get the error of
/// the chain. ``RoutedSession/respond(to:maxTokens:observing:)`` throws the
/// failure itself when the stream of its message ends with this event and no
/// error.
public struct AnswerFailure: Error, Sendable, Equatable {
    /// Why a chain gave no answer.
    public enum Reason: Sendable, Equatable {
        /// A cancel stopped the chain: ``RoutedSession/cancel()``,
        /// ``RoutedSession/cancel(message:)``, or the cancel of a caller that
        /// waited for the answer.
        case cancelled

        /// The chain failed with an error. The text is the description of the
        /// error.
        case error(String)
    }

    /// Every caller message the chain delivered, in the order it delivered
    /// them. Empty for a chain that delivered mail alone.
    public let messageIds: [MessageID]

    /// Why the chain gave no answer.
    public let reason: Reason

    /// Creates a failure record.
    ///
    /// The session makes one for each chain that ends with no answer. A
    /// consumer can make one again, for example for a fake event stream in
    /// its own tests.
    ///
    /// - Parameters:
    ///   - messageIds: The caller messages the chain delivered.
    ///   - reason: Why the chain gave no answer.
    public init(messageIds: [MessageID], reason: Reason) {
        self.messageIds = messageIds
        self.reason = reason
    }
}

/// The reducer behind ``SessionAnswer``: the session applies each
/// ``SessionEvent`` of a chain to it, one at a time, and makes the answer from
/// it when the chain ends.
struct SessionAnswerReducer {
    /// The usage of the chain so far, or `nil` before a submission carried
    /// usage.
    private var usage: TokenUsage?

    /// Every ``SessionEvent/compaction(_:)`` result so far, in compaction order.
    private var compactions: [CompactionResult] = []

    /// The recorded tool calls so far, in record order.
    private var toolCalls: [ToolCallEntry] = []

    /// The live invocation records so far, in open order, one for each run.
    private var toolInvocations: [ToolInvocationRecord] = []

    /// Where each run's record sits in ``toolInvocations``, keyed by
    /// correlation id.
    private var invocationIndexByCorrelationID: [String: Int] = [:]

    /// Applies one ``SessionEvent`` of the chain.
    ///
    /// - Parameter event: The event to apply.
    mutating func apply(_ event: SessionEvent) {
        switch event {
        case .toolCall(let id, let name, let argumentsJSON):
            toolCalls.append(
                ToolCallEntry(id: id, name: name, argumentsJSON: argumentsJSON, status: .running, summary: nil))
        case .toolStatus(let id, let status, let summary, let output):
            updateToolCall(id: id, status: status, summary: summary, output: output)
        case .toolInvocation(let record):
            applyToolInvocation(record)
        case .compaction(let result):
            compactions.append(result)
        case .submissionEnded(let end):
            accumulate(end.usage)
        case .submissionQueued, .submissionStarted, .answered, .answerFailed, .textDelta, .textReset,
            .reasoningDelta, .entryRecorded, .discoveryPrimingFailed, .generationStalled, .repetitionStopped,
            .runSettled, .toolCallReport, .elicitationRequested, .generationCall:
            // Deliberately not carried by the answer. The frames of a
            // submission and of an answer are the structure the answer sums.
            // The reply is the final reply of the chain, not a reduction of
            // its text fragments: a continuation writes its own reply, and
            // only the last one answers. Reasoning is model prose the reply
            // excludes, and the recorded-entry closes exist for consumers
            // (like ``SessionProjection``) that key rows on durable SDK entry
            // ids. The priming report, the stall report, the repetition stop
            // report (its submission's ``SessionEvent/submissionEnded(_:)``
            // names the stop), a background run's settlement, a call's
            // attachments, a pending elicitation, and one generation call's
            // usage (``SessionEvent/submissionEnded(_:)`` sums them) are
            // live-driver concerns. The `observing` callback of
            // ``RoutedSession/respond(to:maxTokens:observing:)`` still
            // delivers every one of them raw.
            break
        }
    }

    /// The answer the chain made.
    ///
    /// - Parameters:
    ///   - reply: The final reply of the chain.
    ///   - messageIds: The caller messages the chain delivered.
    /// - Returns: The answer.
    func answer(reply: String, messageIds: [MessageID]) -> SessionAnswer {
        SessionAnswer(
            reply: reply, messageIds: messageIds, usage: usage, compactions: compactions, toolCalls: toolCalls,
            toolInvocations: toolInvocations)
    }

    /// Adds the usage of one submission to the usage of the chain.
    ///
    /// - Parameter submissionUsage: The usage of the submission, or `nil`
    ///   when its backend reported none.
    private mutating func accumulate(_ submissionUsage: TokenUsage?) {
        guard let submissionUsage else { return }
        usage =
            usage.map { total in
                TokenUsage(
                    tokensIn: total.tokensIn + submissionUsage.tokensIn,
                    tokensOut: total.tokensOut + submissionUsage.tokensOut,
                    contextFill: submissionUsage.contextFill,
                    finishReason: submissionUsage.finishReason)
            } ?? submissionUsage
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
    /// Sends one prompt through ``streamEvents(to:maxTokens:)`` and returns
    /// the ``SessionAnswer`` that its ``SessionEvent/answered(_:)`` event
    /// carries. Cancelling the awaiting task cancels the message.
    ///
    /// - Parameters:
    ///   - prompt: The prompt to respond to.
    ///   - maxTokens: The maximum number of tokens to generate, or `nil` for the resolved context of the model.
    ///   - observing: A callback that receives each raw ``SessionEvent`` as it arrives, or `nil`.
    /// - Returns: The final answer of the chain that carried the prompt.
    /// - Throws: Whatever the chain throws, after `observing` has seen every
    ///   event. `CancellationError` when the awaiting task is cancelled before
    ///   the answer. The ``AnswerFailure`` of a
    ///   ``SessionEvent/answerFailed(_:)`` event when the stream ends with it
    ///   and with no error.
    public func respond(
        to prompt: String,
        maxTokens: Int? = nil,
        observing: (@Sendable (SessionEvent) -> Void)? = nil
    ) async throws -> SessionAnswer {
        try await SessionAnswer.awaitEnd(of: streamEvents(to: prompt, maxTokens: maxTokens), observing: observing)
    }
}

extension SessionAnswer {
    /// Reads the event stream of one message to its end, and gives the answer
    /// that its ``SessionEvent/answered(_:)`` event carries.
    ///
    /// - Parameters:
    ///   - events: The event stream of one message.
    ///   - observing: A callback that receives each raw ``SessionEvent`` as it
    ///     arrives, or `nil`.
    /// - Returns: The final answer of the chain that carried the message.
    /// - Throws: Whatever the stream throws. `CancellationError` when the
    ///   task that reads the stream is cancelled before the answer. The
    ///   ``AnswerFailure`` of an ``SessionEvent/answerFailed(_:)`` event when
    ///   the stream ends with it and with no error.
    static func awaitEnd(
        of events: AsyncThrowingStream<SessionEvent, Error>,
        observing: (@Sendable (SessionEvent) -> Void)?
    ) async throws -> SessionAnswer {
        var end: Result<SessionAnswer, AnswerFailure>?
        // The loop does not stop at the end of the answer. The session
        // finishes the stream with the error of a failed chain after its
        // `answerFailed`, and the caller gets that error, not a copy of it.
        for try await event in events {
            observing?(event)
            if case .answered(let answer) = event {
                end = .success(answer)
            } else if case .answerFailed(let failure) = event {
                end = .failure(failure)
            }
        }
        if case .success(let answer) = end {
            return answer
        }
        // A stream whose reader is cancelled ends with no error, and it can
        // end before the end of the answer arrives.
        try Task.checkCancellation()
        guard let end else {
            // The pump sends the end of the answer on the stream of the first
            // message of a chain, and a stream message goes alone in its
            // submission. A stream that ends with no error, no end of the
            // answer, and no cancel is a defect of the session.
            preconditionFailure("the event stream of a message finished with no end of its answer")
        }
        return try end.get()
    }
}
