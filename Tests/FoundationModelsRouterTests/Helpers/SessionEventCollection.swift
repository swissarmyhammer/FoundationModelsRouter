import FoundationModels

@testable import FoundationModelsRouter

/// Drains `stream` into an array, in order.
///
/// The one place a test that reads a whole event stream states that loop, so
/// the loop lives once instead of at each site.
///
/// - Parameter stream: The stream to drain.
/// - Returns: Every event the stream yielded, in order.
/// - Throws: Whatever the stream throws.
func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
    var events: [SessionEvent] = []
    for try await event in stream {
        events.append(event)
    }
    return events
}

/// Drains a session-scoped `stream` into an array, in order.
///
/// ``RoutedSession/close()`` finishes the stream, so a caller drains it after
/// it closes the session the stream came from.
///
/// - Parameter stream: The stream to drain.
/// - Returns: Every event the stream yielded, in order.
func collect(_ stream: AsyncStream<SessionEvent>) async -> [SessionEvent] {
    await stream.reduce(into: []) { $0.append($1) }
}

/// Drains `session`'s `streamEvents(to:)` for one turn into an array, in
/// production order.
///
/// - Parameters:
///   - session: The session to drive one turn on.
///   - prompt: The prompt the turn answers.
/// - Returns: The turn's events, in order.
/// - Throws: Whatever the turn throws.
func collectEvents(_ session: RoutedSession, prompt: String) async throws -> [SessionEvent] {
    try await collect(session.streamEvents(to: prompt))
}

extension Sequence<SessionEvent> {
    /// The compaction results among these events, in order.
    var compactionResults: [CompactionResult] {
        compactMap { event in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
    }

    /// The text these events streamed, joined.
    var streamedText: String {
        compactMap { event in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
    }

    /// The start records of the submissions among these events, in order.
    var submissionStarts: [SubmissionStart] {
        compactMap { event in
            if case .submissionStarted(let start) = event { return start }
            return nil
        }
    }

    /// The end records of the submissions among these events, in order.
    var submissionEnds: [SubmissionEnd] {
        compactMap { event in
            if case .submissionEnded(let end) = event { return end }
            return nil
        }
    }

    /// The final answers among these events, in order.
    var answers: [SessionAnswer] {
        compactMap { event in
            if case .answered(let answer) = event { return answer }
            return nil
        }
    }

    /// The failed answers among these events, in order.
    var answerFailures: [AnswerFailure] {
        compactMap { event in
            if case .answerFailed(let failure) = event { return failure }
            return nil
        }
    }
}

extension Transcript {
    /// The text of every `.prompt` entry of this transcript, in order.
    var promptTexts: [String] {
        compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }
}

extension SessionEvent {
    /// Whether this event is an open ``ToolInvocationRecord``.
    var isOpenInvocation: Bool {
        carriedInvocation.map { $0.closedAt == nil } ?? false
    }

    /// Whether this event is a close ``ToolInvocationRecord``.
    var isCloseInvocation: Bool {
        carriedInvocation.map { $0.closedAt != nil } ?? false
    }

    /// The ``ToolInvocationRecord`` this event carries, or `nil` for any other event.
    var carriedInvocation: ToolInvocationRecord? {
        if case .toolInvocation(let record) = self { return record }
        return nil
    }

    /// The ``ToolCallReport`` this event carries, or `nil` for any other event.
    var carriedReport: ToolCallReport? {
        if case .toolCallReport(let report) = self { return report }
        return nil
    }
}
