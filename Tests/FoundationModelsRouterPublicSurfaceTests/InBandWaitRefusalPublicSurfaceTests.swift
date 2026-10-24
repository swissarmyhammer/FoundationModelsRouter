import Testing

import FoundationModelsRouter

/// Holds the refusal of a wait that can never end to the access level a
/// consumer outside this package needs (tasks ^1psqdm9 and ^hga4td7): an
/// in-band tool body that waits for an answer of its own session is refused
/// with ``RoutedSessionError/inBandWaitForOwnSession(sessionID:)``.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("RoutedSessionError surface over a plain import")
struct InBandWaitRefusalPublicSurfaceTests {
    /// The label a consumer shows for `error`, or `nil` for an error that is
    /// not a refused wait.
    ///
    /// - Parameter error: The error a call threw.
    /// - Returns: The label, which names the session.
    private static func refusalLabel(for error: any Error) -> String? {
        guard case .inBandWaitForOwnSession(let sessionID) = error as? RoutedSessionError else { return nil }
        return "a tool waited for its own session \(sessionID)"
    }

    @Test("a consumer matches the refusal of an in-band wait for its own session, and reads the session")
    func aConsumerMatchesTheRefusedWait() {
        let sessionID = ULID.generate()
        let refusal = RoutedSessionError.inBandWaitForOwnSession(sessionID: sessionID)

        #expect(Self.refusalLabel(for: refusal) == "a tool waited for its own session \(sessionID)")
        #expect(refusal.errorDescription?.contains(sessionID.description) == true)
    }
}
