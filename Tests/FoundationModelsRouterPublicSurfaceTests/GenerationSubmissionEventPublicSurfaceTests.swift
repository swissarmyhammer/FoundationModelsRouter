import Testing

import FoundationModelsRouter

/// Holds the two events that report the wait of a submission for the worker of
/// its model to the access level a consumer outside this package needs (tasks
/// ^ake8sax and ^1psqdm9). A consumer such as an agent host shows "waiting for
/// the model" between ``SessionEvent/submissionQueued`` and
/// ``SessionEvent/submissionStarted``. A submission that finds the worker free
/// sends only ``SessionEvent/submissionStarted``.
///
/// The import is plain, with no `@testable`, so a case that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("SessionEvent submission events over a plain import")
struct GenerationSubmissionEventPublicSurfaceTests {
    /// The label a consumer shows for `event`, or `nil` for an event that is
    /// not about the start of a submission.
    ///
    /// - Parameter event: The event to read.
    /// - Returns: The label.
    private static func submissionLabel(for event: SessionEvent) -> String? {
        switch event {
        case .submissionQueued:
            "waiting for the model"
        case .submissionStarted:
            "generating"
        default:
            nil
        }
    }

    @Test("a consumer matches the two submission events by name: a wait, and a start")
    func aConsumerMatchesTheSubmissionEvents() {
        #expect(Self.submissionLabel(for: .submissionQueued) == "waiting for the model")
        #expect(Self.submissionLabel(for: .submissionStarted) == "generating")
        #expect(Self.submissionLabel(for: .textReset) == nil)
    }
}
