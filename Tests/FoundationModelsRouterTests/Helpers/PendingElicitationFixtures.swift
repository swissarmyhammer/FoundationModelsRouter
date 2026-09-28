import Foundation

@testable import FoundationModelsRouter

/// The helpers that the suites share when a test holds an elicitation
/// pending on the run plane of a session: `ElicitationRoutingTests` and
/// `SessionRunPlaneTests`. Each helper is in one place only.
enum PendingElicitationFixtures {
    /// The number of checks that ``eventually(_:)`` makes before its last
    /// check.
    private static let pollAttempts = 1_000

    /// The pause between two checks of ``eventually(_:)``, in nanoseconds.
    private static let pollIntervalNanoseconds: UInt64 = 1_000_000

    /// Checks `condition` again and again, with a pause between the checks,
    /// until it is true. A test uses it to wait until an `elicit(_:)` or
    /// `awaitAnswer(to:)` task has registered its continuation, with no race.
    ///
    /// - Parameter condition: The condition to check.
    /// - Returns: `true` when the condition became true, else the result of
    ///   the last check.
    static func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<pollAttempts {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return await condition()
    }

    /// Makes a form-mode request that asks for one string, the name.
    ///
    /// - Parameter elicitationId: The id of the request.
    /// - Returns: The request.
    static func formRequest(elicitationId: ULID) -> ElicitationRequest {
        ElicitationRequest(
            message: "name?",
            elicitationId: elicitationId,
            requestedSchema: ElicitationRequestedSchema(properties: [
                "name": .string(ElicitationStringSchema())
            ])
        )
    }
}
