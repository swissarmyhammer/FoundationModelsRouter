import Testing

@testable import FoundationModelsRouter

/// The bounded waits that the suites of the message pump share.
///
/// Each suite that drives a session over a scripted backend waits for the
/// same two things: prompts that reach the backend, and the end of the pump.
/// One copy of each wait is here, so that a change to a wait goes to each
/// suite.
extension BoundedWait {
    /// Waits, bounded, until a backend received `count` prompts.
    ///
    /// - Parameters:
    ///   - count: How many prompts to wait for.
    ///   - prompts: Reads the prompts that the backend received so far.
    /// - Throws: ``SignalNeverArrived`` when the prompts did not arrive
    ///   inside the bound.
    static func awaitPrompts(_ count: Int, in prompts: @Sendable () -> [String]) async throws {
        guard await conditionReached("\(count) prompts reaching the backend", when: { prompts().count >= count })
        else { throw SignalNeverArrived() }
    }

    /// Waits, bounded, until the pump of `session` ends.
    ///
    /// - Parameter session: The session whose pump is watched.
    /// - Returns: `true` when the pump ended inside the bound.
    static func pumpStops(on session: any RoutedSession) async -> Bool {
        await conditionReached("the pump of the session ending") {
            await session.isPumpRunning == false
        }
    }
}
