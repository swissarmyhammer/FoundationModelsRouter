import Foundation
import Synchronization
import Testing

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

    /// The gate that holds each completion post before it goes to the
    /// downstream sink, or `nil` when no gate holds it.
    private let completionGate: RunLatch?

    /// The gate that holds each end post before it goes to the downstream
    /// sink, or `nil` when no gate holds it.
    private let endGate: RunLatch?

    /// Signalled after each post.
    let changes = ChangeSignal()

    /// Makes a counter with no post.
    ///
    /// - Parameters:
    ///   - downstream: The sink that gets each posted event before the count
    ///     goes up. Pass `session.outbox` to reach the journal of the
    ///     session. The default is `nil`: the events go nowhere.
    ///   - completionGate: The gate that holds each completion post
    ///     (``post(elicitationCompleted:)``) until it opens. While the post
    ///     waits, the run plane keeps the id of the question in
    ///     `RunPlane.completingElicitations()`. The default is `nil`: no gate
    ///     holds the post.
    ///   - endGate: The gate that holds each end post
    ///     (``post(elicitationEnded:response:)``) until it opens. While the
    ///     post waits, the run plane keeps the id of the question in
    ///     `RunPlane.endingElicitations()`. The default is `nil`: no gate
    ///     holds the post.
    init(
        forwardingTo downstream: (any OperationEventSink)? = nil, holdingCompletionsAt completionGate: RunLatch? = nil,
        holdingEndsAt endGate: RunLatch? = nil
    ) {
        self.downstream = downstream
        self.completionGate = completionGate
        self.endGate = endGate
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

    /// The ids of each completion that ``post(elicitationCompleted:)`` got,
    /// in order.
    private let completions = Mutex<[ULID]>([])

    /// The number of completions so far. A completion is not a post, so
    /// ``postCount`` does not count it.
    var completionCount: Int { completions.withLock { $0.count } }

    /// Waits until the completion gate opens, when there is one. Then sends
    /// the completion to the downstream sink, keeps its id, and signals
    /// ``changes``.
    ///
    /// The downstream post ends after the journal of the session handled
    /// the completion, so a test that waits for the count reads the output
    /// of that completion.
    ///
    /// - Parameter elicitationId: The id of the question that completed.
    func post(elicitationCompleted elicitationId: ULID) async {
        await completionGate?.waitUntilOpen()
        await downstream?.post(elicitationCompleted: elicitationId)
        completions.withLock { $0.append(elicitationId) }
        changes.signal()
    }

    /// Waits until at least `expected` completions came.
    ///
    /// - Parameter expected: The number of completions to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    func waitForCompletions(_ expected: Int) async throws {
        try await changes.wait(until: { completionCount >= expected })
    }

    /// The number of end posts that came to this sink so far, also the ones
    /// that the end gate still holds.
    private let arrivedEnds = Mutex(0)

    /// The number of end posts that came to this sink so far, also the ones
    /// that the end gate still holds.
    var arrivedEndCount: Int { arrivedEnds.withLock { $0 } }

    /// Counts the end post and signals ``changes``, then waits until the end
    /// gate opens, when there is one. Then sends the end of the question to
    /// the downstream sink. The run plane posts it when a cancel of the run
    /// plane ends the question, and the downstream post ends after the
    /// journal of the session handled it.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question that ended.
    ///   - response: The answer that the run of the question gets.
    func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
        arrivedEnds.withLock { $0 += 1 }
        changes.signal()
        await endGate?.waitUntilOpen()
        await downstream?.post(elicitationEnded: elicitationId, response: response)
    }

    /// Waits until at least `expected` end posts came to this sink, also
    /// when the end gate still holds them.
    ///
    /// - Parameter expected: The number of end posts to wait for.
    /// - Throws: ``ConditionNeverHeld`` when the waiting task was cancelled
    ///   first.
    func waitForArrivedEnds(_ expected: Int) async throws {
        try await changes.wait(until: { arrivedEndCount >= expected })
    }
}

/// The helpers that the suites share when a test holds an elicitation
/// pending on the run plane of a session: `ElicitationRoutingTests`,
/// `SessionRunPlaneTests`, `SessionWorkEventTests`,
/// `ElicitationEndedEventTests` and `ElicitationCompletedEventTests`. Each
/// helper is in one place only.
enum PendingElicitationFixtures {
    /// The count of the ends of one question that ended with no answer of
    /// the client.
    private static let oneEnd = 1

    /// The response that the run plane gives to each question of a stopped
    /// run.
    static let runCancelled = ElicitationResponse.cancel(reason: RunPlane.runCancelledReason)

    /// Each ``SessionEvent/elicitationEnded(_:)`` of `outputs`, with its
    /// origin and its position.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: The ends, in order.
    static func ends(in outputs: [SessionOutput]) -> [(position: Int, origin: Origin, end: ElicitationEnd)] {
        outputs.enumerated().compactMap { position, output in
            guard case .elicitationEnded(let end) = output.event else { return nil }
            return (position, output.origin, end)
        }
    }

    /// The one ``SessionEvent/elicitationEnded(_:)`` of `outputs`, checked
    /// against the question: the same id, and the cancel of a stopped run
    /// (``runCancelled``).
    ///
    /// - Parameters:
    ///   - outputs: Outputs of a session.
    ///   - id: The id of the question.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Returns: The position and the origin of the end.
    /// - Throws: When `outputs` hold no end.
    static func soleEnd(
        in outputs: [SessionOutput], of id: ULID, sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> (position: Int, origin: Origin) {
        let found = ends(in: outputs)
        #expect(
            found.count == oneEnd, "expected one end of the question, got \(found.count)",
            sourceLocation: sourceLocation)
        let end = try #require(found.first, sourceLocation: sourceLocation)
        #expect(
            end.end == ElicitationEnd(elicitationId: id, response: runCancelled), sourceLocation: sourceLocation)
        return (end.position, end.origin)
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
