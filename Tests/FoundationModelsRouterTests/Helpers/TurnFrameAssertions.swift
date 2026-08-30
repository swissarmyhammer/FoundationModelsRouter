import Testing

@testable import FoundationModelsRouter

/// Checks that `events` opens with the ``SessionEvent/turnStarted(_:)``
/// correlation frame every turn now reports, and hands back what follows it.
///
/// The one place a test that reads "the turn's first real event" states that
/// expectation, so the frame is asserted rather than skipped past, and so the
/// statement lives once instead of at each site.
///
/// - Parameters:
///   - events: One turn's events, in order.
///   - promptId: The queued prompt the frame must name, or `nil` for a turn
///     whose prompt came straight from its caller.
/// - Returns: `events` without its opening frame, or `events` unchanged when the
///   frame was missing (the failure is already recorded by then).
func eventsAfterTurnFrame(
    _ events: [SessionEvent],
    promptId: PromptID? = nil
) -> [SessionEvent] {
    guard case .turnStarted(let start) = events.first else {
        Issue.record("expected the turn to open with .turnStarted, got \(String(describing: events.first))")
        return events
    }
    #expect(start.promptId == promptId)
    return Array(events.dropFirst())
}
