import Testing

import FoundationModelsRouter

/// Holds ``UserPresence`` and ``SessionConfiguration/userPresence`` to the
/// access level a consumer outside this package needs (task ^0hps8jg). A host
/// that runs a session with no user sets the presence when it vends the
/// session.
///
/// The import is plain, with no `@testable`, and this file does not import
/// FoundationModelsExtras. So the router must re-export ``UserPresence``, and
/// a member that loses `public` stops this file from compiling before a
/// single test runs.
@Suite("UserPresence and the user presence of a configuration over a plain import")
struct UserPresencePublicSurfaceTests {
    @Test("a consumer sets the user presence on a configuration and reads the default")
    func aConsumerSetsTheUserPresence() {
        var configuration = SessionConfiguration(userPresence: .headless)
        #expect(configuration.userPresence == .headless)

        configuration.userPresence = .interactive
        #expect(configuration.userPresence == SessionConfiguration().userPresence)
    }
}
