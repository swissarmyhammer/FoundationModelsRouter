import Testing

@testable import FoundationModelsRouter

/// A case of ``SessionEvent``, by its name, with no associated value. A test
/// that looks for an event of one kind gives the case here
/// (``position(ofFirst:in:sourceLocation:)``), and does not write a pattern
/// match of its own.
///
/// Each raw value is the name of the case in ``SessionEvent``. A test that
/// looks for a case whose name is not correct finds no event, so the test
/// fails.
enum SessionEventCase: String, Sendable {
    /// ``SessionEvent/answered(_:)``.
    case answered

    /// ``SessionEvent/compaction(_:)``.
    case compaction

    /// ``SessionEvent/compactionFailed(_:)``.
    case compactionFailed

    /// ``SessionEvent/compactionStarted(_:)``.
    case compactionStarted

    /// ``SessionEvent/elicitationRequested(_:)``.
    case elicitationRequested

    /// ``SessionEvent/elicitationEnded(_:)``.
    case elicitationEnded

    /// ``SessionEvent/elicitationCompleted(_:)``.
    case elicitationCompleted

    /// ``SessionEvent/runSettled(_:)``.
    case runSettled

    /// ``SessionEvent/runProgress(_:)``.
    case runProgress

    /// ``SessionEvent/runMessage(_:)``.
    case runMessage

    /// ``SessionEvent/toolInvocation(_:toolCallID:)``.
    case toolInvocation

    /// ``SessionEvent/toolCallReport(_:)``.
    case toolCallReport

    /// ``SessionEvent/toolDisplay(_:)``.
    case toolDisplay

    /// Whether `event` is of this case.
    ///
    /// - Parameter event: An event of a session.
    /// - Returns: `true` when the name of the case of `event` is this name.
    func matches(_ event: SessionEvent) -> Bool {
        rawValue == event.caseName
    }
}

extension SessionEvent {
    /// The name of the case of this event, with no associated value: for
    /// example `answered` for ``SessionEvent/answered(_:)``, and `workEnded`
    /// for ``SessionEvent/workEnded``.
    var caseName: String {
        Mirror(reflecting: self).children.first?.label ?? String(describing: self)
    }
}

/// The `.elicitation` event of the first
/// ``SessionEvent/elicitationRequested(_:)`` of `outputs`: the question of a
/// run, with the `completionToken` of the run as its `correlationID`.
///
/// - Parameters:
///   - outputs: Outputs of a session.
///   - sourceLocation: The place of the call, for the failure.
/// - Returns: The event of the question.
/// - Throws: When `outputs` holds no question.
func firstQuestion(
    in outputs: [SessionOutput], sourceLocation: SourceLocation = #_sourceLocation
) throws -> OperationEvent {
    let question = outputs.lazy.compactMap { output -> OperationEvent? in
        guard case .elicitationRequested(let event) = output.event else { return nil }
        return event
    }.first
    return try #require(question, "the output has no question", sourceLocation: sourceLocation)
}

/// The test of a question with the id `id`.
///
/// - Parameter id: The id of a question.
/// - Returns: A test that accepts ``SessionEvent/elicitationRequested(_:)`` of that question.
func isQuestion(_ id: ULID) -> (SessionEvent) -> Bool {
    { event in
        guard case .elicitationRequested(let question) = event else { return false }
        return question.elicitation?.elicitationId == id
    }
}

/// The position of the first output of `outputs` whose event `matches`.
///
/// - Parameters:
///   - outputs: Outputs of a session.
///   - matches: The test of an event.
/// - Returns: The position, or `nil` when no event matches.
func firstPosition(in outputs: [SessionOutput], where matches: (SessionEvent) -> Bool) -> Int? {
    outputs.firstIndex { matches($0.event) }
}

/// The position of the first output of `outputs` whose event is `event`.
///
/// - Parameters:
///   - event: The event to look for.
///   - outputs: Outputs of a session.
///   - sourceLocation: The place of the call, for the failure.
/// - Returns: The position.
/// - Throws: When `outputs` does not have the event.
func position(
    of event: SessionEvent, in outputs: [SessionOutput], sourceLocation: SourceLocation = #_sourceLocation
) throws -> Int {
    try #require(firstPosition(in: outputs) { $0 == event }, "the output has no \(event)", sourceLocation: sourceLocation)
}

/// The position of the first output of `outputs` whose event is one of
/// `cases`.
///
/// - Parameters:
///   - cases: The cases to look for.
///   - outputs: Outputs of a session.
///   - sourceLocation: The place of the call, for the failure.
/// - Returns: The position.
/// - Throws: When no event of `outputs` is one of `cases`.
func position(
    ofFirst cases: SessionEventCase..., in outputs: [SessionOutput], sourceLocation: SourceLocation = #_sourceLocation
) throws -> Int {
    try #require(
        firstPosition(in: outputs) { event in cases.contains { $0.matches(event) } },
        "the output has no \(cases)", sourceLocation: sourceLocation)
}
