import Foundation
import Synchronization

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Counts the elicitation requests that the run plane of a session posted,
/// and keeps each posted event.
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

    /// Each event that ``post(event:)`` got, in order.
    private let events = Mutex<[OperationEvent]>([])

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

    /// Each event that ``post(event:)`` got, in order. A test that holds an
    /// event back from the journal of a session posts it to the session
    /// later.
    var postedEvents: [OperationEvent] { events.withLock { $0 } }

    /// Records one post, and signals ``changes``.
    func record() {
        count.withLock { $0 += 1 }
        changes.signal()
    }

    /// Sends `event` to the downstream sink, keeps it, then records one post.
    ///
    /// - Parameter event: The posted event.
    func post(event: OperationEvent) async {
        await downstream?.post(event: event)
        events.withLock { $0.append(event) }
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
/// pending on the run plane of a session: `ElicitationRoutingTests`,
/// `SessionRunPlaneTests` and `SessionWorkEventTests`. Each helper is in one
/// place only.
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

    /// Binds a ``ToolContext`` over `session`'s own run plane — the same shape
    /// the invoker binds around a wrapped tool call — so a test can suspend a
    /// real ``ToolContext/elicit(_:)`` continuation on the session.
    ///
    /// - Parameters:
    ///   - session: The session whose run plane the context binds.
    ///   - sink: Where the context posts its events. Defaults to a sink that
    ///     drops them; pass `session.outbox` to reach the session's journal.
    ///   - completionToken: The token of the run that the context belongs
    ///     to. Each open question of the context carries it. The default is
    ///     a new token of no run.
    /// - Returns: The context.
    static func makeContext(
        for session: any RoutedSession,
        postingTo sink: any OperationEventSink = DiscardingOperationEventSink(),
        completionToken: String = RunPlane.makeCompletionToken()
    ) -> ToolContext {
        ToolContext(
            sessionID: session.id,
            runPlane: session.runPlane,
            sink: sink,
            tool: "fake",
            op: "ask user",
            completionToken: completionToken,
            isCancelled: { false }
        )
    }
}
