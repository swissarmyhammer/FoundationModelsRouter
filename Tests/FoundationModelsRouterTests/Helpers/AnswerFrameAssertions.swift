import Testing

@testable import FoundationModelsRouter

/// Checks the frame of one answer in `events`, and gives back the events
/// inside the frame.
///
/// The frame of an answer is:
/// - Each ``SessionEvent/submissionStarted(_:)`` has one
///   ``SessionEvent/submissionEnded(_:)`` with the same id after it.
/// - No submission ends two times.
/// - The events end with exactly one ``SessionEvent/answered(_:)`` or
///   ``SessionEvent/answerFailed(_:)``, and it is the last event.
///
/// This is the one place where a test that reads "the content of the answer"
/// states that expectation. Thus the test asserts the frame and does not skip
/// it, and the statement is in one place, not at each site.
///
/// - Parameter events: The events of one answer, in order.
/// - Returns: `events` without the submission starts, the submission ends and
///   the end of the answer. A failed check is recorded as an issue.
func eventsInsideAnswerFrame(_ events: [SessionEvent]) -> [SessionEvent] {
    let answerEnds = events.answers.count + events.answerFailures.count
    #expect(answerEnds == 1, "expected exactly one end of the answer, got \(answerEnds)")
    #expect(
        events.last?.isAnswerEnd == true,
        "expected the end of the answer as the last event, got \(String(describing: events.last))")

    let endedIds = events.submissionEnds.map(\.submissionId)
    #expect(Set(endedIds).count == endedIds.count, "a submission ended more than one time: \(endedIds)")
    for start in events.submissionStarts {
        let startIndex = events.firstIndex(of: .submissionStarted(start))
        let endIndex = events.firstIndex { event in
            if case .submissionEnded(let end) = event { return end.submissionId == start.submissionId }
            return false
        }
        #expect(endIndex != nil, "submission \(start.submissionId) started and did not end")
        if let startIndex, let endIndex {
            #expect(startIndex < endIndex, "submission \(start.submissionId) ended before it started")
        }
    }
    return events.filter { !$0.isAnswerFrame }
}

extension SessionEvent {
    /// Whether this event ends an answer: ``SessionEvent/answered(_:)`` or
    /// ``SessionEvent/answerFailed(_:)``.
    var isAnswerEnd: Bool {
        switch self {
        case .answered, .answerFailed: return true
        default: return false
        }
    }

    /// Whether this event is part of the frame of an answer: a submission
    /// start, a submission end, or the end of the answer.
    var isAnswerFrame: Bool {
        switch self {
        case .submissionStarted, .submissionEnded: return true
        default: return isAnswerEnd
        }
    }
}
