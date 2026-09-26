import Testing

import FoundationModelsRouter

/// Holds ``MailDeliveryPause``, ``SessionEvent/mailDeliveryPaused(_:)`` and
/// ``SessionConfiguration/mailOnlyAnswerLimit`` to the access level a consumer
/// outside this package needs (task ^9bxas0w). A host sets the limit when it
/// vends a session, reads the pause from the session-wide feed, and makes the
/// record itself in a fake event stream of its own tests.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("MailDeliveryPause and the mail-only answer limit over a plain import")
struct MailDeliveryPausePublicSurfaceTests {
    /// The limit of the fake pause and of the configuration.
    private static let limit = 5

    /// The mail of the fake pause.
    private static let heldMail = [
        OperationEvent(tool: "status", op: "check", correlationID: "run-1", kind: .completed, detail: "done")
    ]

    @Test("a consumer makes a pause, reads each field, and matches the event case")
    func aConsumerMakesAndReadsAPause() {
        let pause = MailDeliveryPause(limit: Self.limit, heldMail: Self.heldMail)
        let event = SessionEvent.mailDeliveryPaused(pause)

        #expect(pause.limit == Self.limit)
        #expect(pause.heldMail == Self.heldMail)
        #expect(!pause.description.isEmpty)
        #expect(event == .mailDeliveryPaused(MailDeliveryPause(limit: Self.limit, heldMail: Self.heldMail)))
    }

    @Test("a consumer sets the limit on a configuration and reads the named default")
    func aConsumerSetsTheLimit() {
        var configuration = SessionConfiguration(mailOnlyAnswerLimit: Self.limit)
        #expect(configuration.mailOnlyAnswerLimit == Self.limit)

        configuration.mailOnlyAnswerLimit = SessionConfiguration.defaultMailOnlyAnswerLimit
        #expect(configuration.mailOnlyAnswerLimit == SessionConfiguration().mailOnlyAnswerLimit)
    }
}
