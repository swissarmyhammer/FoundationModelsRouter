import Testing

@testable import FoundationModelsRouter

/// Checks the frame of one answer in `allEvents`, and gives back the events
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
/// The work events (``SessionEvent/workStarted``, ``SessionEvent/workEnded``)
/// are no part of an answer: the session sends them around the work, and
/// ``SessionWorkEventTests`` checks them. Thus this check ignores them.
///
/// - Parameter allEvents: The events of one answer, in order.
/// - Returns: `allEvents` without the work events, the deliveries of mail, the
///   submission starts, the submission ends and the end of the answer. A
///   failed check is recorded as an issue.
func eventsInsideAnswerFrame(_ allEvents: [SessionEvent]) -> [SessionEvent] {
    let events = allEvents.filter { !$0.isWorkEvent }
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

extension [SessionEvent] {
    /// Splits the events of answers that come one after the other at each end
    /// of an answer, and checks the frame of each part with
    /// ``eventsInsideAnswerFrame(_:)``.
    ///
    /// The work events are no part of an answer, so this method drops them
    /// before it splits. The events after the last end of an answer are a
    /// part too, so their check fails: each event must be in the frame of an
    /// answer.
    ///
    /// - Returns: The events inside each frame, one array for each answer, in
    ///   order. A failed check is recorded as an issue.
    func eventsInsideEachAnswerFrame() -> [[SessionEvent]] {
        let answerEvents = filter { !$0.isWorkEvent }
        let partEnds = answerEvents.indices.filter { answerEvents[$0].isAnswerEnd }.map { $0 + 1 }
        let partStarts = [answerEvents.startIndex] + partEnds
        return zip(partStarts, partEnds + [answerEvents.endIndex])
            .filter { start, end in start < end }
            .map { start, end in eventsInsideAnswerFrame(Array(answerEvents[start..<end])) }
    }
}

extension SessionEvent {
    /// Whether this event is a work event: ``SessionEvent/workStarted`` or
    /// ``SessionEvent/workEnded``.
    var isWorkEvent: Bool {
        switch self {
        case .workStarted, .workEnded: return true
        default: return false
        }
    }

    /// Whether this event ends the work of the session:
    /// ``SessionEvent/workEnded``.
    var isWorkEnd: Bool {
        if case .workEnded = self { return true }
        return false
    }

    /// Whether this event ends an answer: ``SessionEvent/answered(_:)`` or
    /// ``SessionEvent/answerFailed(_:)``.
    var isAnswerEnd: Bool {
        switch self {
        case .answered, .answerFailed: return true
        default: return false
        }
    }

    /// Whether this event is part of the frame of an answer: the delivery of
    /// a mail, a submission start, a submission end, or the end of the
    /// answer.
    var isAnswerFrame: Bool {
        switch self {
        case .mailDelivered, .submissionStarted, .submissionEnded: return true
        default: return isAnswerEnd
        }
    }
}
