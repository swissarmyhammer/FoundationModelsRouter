import Testing

import FoundationModelsRouter

/// Holds the two events that report a wait for a generation queue place to
/// the access level a consumer outside this package needs (task ^ake8sax). A
/// consumer such as an agent host shows "waiting for the model" between
/// ``SessionEvent/passQueued`` and ``SessionEvent/passStarted``.
///
/// The import is plain, with no `@testable`, so a case that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionEvent pass events over a plain import")
struct GenerationPassEventPublicSurfaceTests {
    /// The label a consumer shows for `event`, or `nil` for an event that is
    /// not about a wait for a queue place.
    ///
    /// - Parameter event: The event to read.
    /// - Returns: The label.
    private static func waitLabel(for event: SessionEvent) -> String? {
        switch event {
        case .passQueued:
            "waiting for the model"
        case .passStarted:
            "generating"
        default:
            nil
        }
    }

    @Test("a consumer matches the two pass events by name")
    func aConsumerMatchesThePassEvents() {
        #expect(Self.waitLabel(for: .passQueued) == "waiting for the model")
        #expect(Self.waitLabel(for: .passStarted) == "generating")
        #expect(Self.waitLabel(for: .textReset) == nil)
    }
}
