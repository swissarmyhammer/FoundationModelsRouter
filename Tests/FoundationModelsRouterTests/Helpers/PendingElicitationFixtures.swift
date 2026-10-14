import Foundation
import Synchronization

@testable import FoundationModelsRouter

/// Counts the elicitation requests that the run plane of a session posted.
///
/// `RunPlane.awaitAnswer(to:runToken:posting:)` makes the elicitation pending
/// before it runs `posting`. Thus each post that this type counts comes after the
/// registration of one pending elicitation. A test waits for the post with
/// ``waitForPosts(_:)`` and then answers the elicitation, with no race.
///
/// Bind it as the sink of a ``ToolContext`` (each `elicit(_:)` posts one
/// event), or call ``record()`` from the `posting` closure of
/// `awaitAnswer(to:runToken:posting:)`.
final class ElicitationPostings: OperationEventSink {
    /// The number of posts so far.
    private let count = Mutex(0)

    /// The sink that gets each posted event before the count goes up, or
    /// `nil` when the events go nowhere.
    private let downstream: (any OperationEventSink)?

    /// Signalled after each post.
    let changes = ChangeSignal()

    /// Makes a counter with no post.
    ///
    /// - Parameter downstream: The sink that gets each posted event before
    ///   the count goes up. Pass `session.outbox` to reach the journal of the
    ///   session. The default is `nil`: the events go nowhere.
    init(forwardingTo downstream: (any OperationEventSink)? = nil) {
        self.downstream = downstream
    }

    /// The number of posts so far.
    var postCount: Int { count.withLock { $0 } }

    /// Records one post, and signals ``changes``.
    func record() {
        count.withLock { $0 += 1 }
        changes.signal()
    }

    /// Sends `event` to the downstream sink, then records one post.
    ///
    /// - Parameter event: The posted event.
    func post(event: OperationEvent) async {
        await downstream?.post(event: event)
        record()
    }

    /// Waits until at least `expected` posts came.
    ///
    /// - Parameter expected: The number of posts to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    func waitForPosts(_ expected: Int) async throws {
        try await changes.wait(until: { postCount >= expected })
    }
}

/// The helpers that the suites share when a test holds an elicitation
/// pending on the run plane of a session: `ElicitationRoutingTests` and
/// `SessionRunPlaneTests`. Each helper is in one place only.
enum PendingElicitationFixtures {
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
