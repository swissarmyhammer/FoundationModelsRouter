import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The `messageDelivered` event of ``RouterSessionDirectory`` (D199 (f),
/// ACPA-6): each message that the directory delivers gives one event with
/// the sender, the source session of a user message, the target and the
/// text. The event comes when the target gets the message: when the pump of
/// the target takes its mail, before the first output of that answer. A
/// message that waits in the queue of a working target thus gives its event
/// when the turn ends, not when the send puts it in the queue.
///
/// Each test runs on the fixture of ``RouterSessionDirectoryDeliveryTests``:
/// a router that records to a durable root, with a launcher over its
/// scripted profile.
@Suite("RouterSessionDirectory: the messageDelivered event of a message")
struct RouterSessionDirectoryDeliveredEventTests {
    /// The fixture of each test.
    typealias Fixture = RouterSessionDirectoryDeliveryTests.Fixture

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    /// The agent of the test that starts a session.
    private static let agentID = "delivered-event-agent"

    /// An event that no session sends. A test emits it after the step under
    /// test, and reads the events up to it.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// The messages of the `messageDelivered` events up to ``marker``. The
    /// caller emits ``marker`` first.
    ///
    /// - Parameter events: The event feed of the directory, opened before
    ///   the step under test.
    /// - Returns: The delivered messages, in stream order.
    private static func deliveries(
        through events: inout AsyncStream<SessionDirectoryEvent>.Iterator
    ) async -> [SessionMessage] {
        await events.next(through: marker).compactMap { event in
            guard case .messageDelivered(let message) = event else { return nil }
            return message
        }
    }

    /// Sends `message` to the idle live session `target`, waits for its
    /// delivery (a message from a session goes through an inbox file), lets
    /// the turn of the message end, and gives the messages of the
    /// `messageDelivered` events of the send.
    ///
    /// - Parameters:
    ///   - message: The message, to `target`.
    ///   - target: An idle live session.
    ///   - fixture: The fixture of the test.
    /// - Returns: The delivered messages, in stream order.
    /// - Throws: The errors of the send.
    private static func deliveries(
        ofSending message: OutgoingSessionMessage, to target: any RoutedSession, in fixture: Fixture
    ) async throws -> [SessionMessage] {
        var events = fixture.directory.events().makeAsyncIterator()
        _ = try await fixture.directory.sendAndAwaitDelivery(message)
        #expect(await target.awaitIdle())
        fixture.directory.emit(marker)
        return await deliveries(through: &events)
    }

    /// A user message with ``text`` from the UI client and the source
    /// session `source` to the session `target`.
    ///
    /// - Parameters:
    ///   - source: The source session.
    ///   - target: The address of the target.
    /// - Returns: The message.
    private static func userMessage(from source: ULID, to target: SessionAddress) -> OutgoingSessionMessage {
        OutgoingSessionMessage(from: .user(clientID: clientID), to: target, text: text, sourceSession: source)
    }

    /// A new fixture over a scripted backend whose first call holds until a
    /// latch opens.
    ///
    /// - Returns: The latch of the first call, the backend and the fixture.
    /// - Throws: The errors of the fixture.
    private static func makeHeldFixture() async throws -> (
        latch: RunLatch, backend: RouterSessionDirectoryDeliveryTests.Backend, fixture: Fixture
    ) {
        let latch = RunLatch()
        let backend = RouterSessionDirectoryDeliveryTests.Backend(script: [firstCall: .hold(latch)])
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        return (latch, backend, fixture)
    }

    // MARK: - Sender kinds

    /// The production change that makes this test fail: an event that drops
    /// the source session of a user message, a second event, or no event.
    @Test("a user message with a source session gives one event with the user sender, the source, the target and the text")
    func aUserMessageGivesOneEventWithItsSource() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        let target = fixture.makeSession()

        let delivered = try await Self.deliveries(
            ofSending: Self.userMessage(from: source.id, to: .session(target.id)), to: target, in: fixture)

        #expect(delivered.map(\.from) == [.user(clientID: Self.clientID)])
        #expect(delivered.map(\.sourceSession) == [source.id])
        #expect(delivered.map(\.to) == [target.id])
        #expect(delivered.map(\.text) == [Self.text])
        await fixture.close([source, target])
    }

    /// The production change that makes this test fail: an event that does
    /// not name the sender session, a second event, or no event.
    @Test("a session message gives one event with the sender session, the target and the text")
    func aSessionMessageGivesOneEventWithItsSender() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let sender = fixture.makeSession()
        let target = fixture.makeSession()
        let message = OutgoingSessionMessage(from: .session(sender.id), to: .session(target.id), text: Self.text)

        let delivered = try await Self.deliveries(ofSending: message, to: target, in: fixture)

        #expect(delivered.map(\.from) == [.session(sender.id)])
        #expect(delivered.map(\.sourceSession) == [nil])
        #expect(delivered.map(\.to) == [target.id])
        #expect(delivered.map(\.text) == [Self.text])
        await fixture.close([sender, target])
    }

    /// The production change that makes this test fail: a first message of
    /// a started session that gives no event, or an event with another
    /// target or no source session.
    @Test("a user message that starts an agent session gives its event with the new session and the source")
    func anAgentStartGivesTheEventOfTheFirstMessage() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(
            Self.userMessage(from: source.id, to: .agent(id: Self.agentID, folder: nil)))

        let messageID = try #require(receipts.first?.messageID)
        let started = try #require(fixture.launcher.sessions.first)
        let delivered = try #require(await events.nextDelivery(of: messageID))
        #expect(delivered.to == started.id)
        #expect(delivered.sourceSession == source.id)
        await fixture.close([source])
    }

    // MARK: - Order

    /// The production change that makes this test fail: an event that the
    /// directory sends after the first output of the model in the answer of
    /// the message, for example at the first text or at the end of the
    /// answer.
    ///
    /// The model call of the answer holds until its latch opens, so the model
    /// makes no output before then. The test emits ``marker`` while the call
    /// holds. Thus the event feed up to ``marker`` holds the event only when
    /// the directory sent it before each output of the model.
    @Test("the event comes before the first output of the answer of the message")
    func theEventComesBeforeTheFirstOutput() async throws {
        let (latch, backend, fixture) = try await Self.makeHeldFixture()
        let source = fixture.makeSession()
        let target = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(Self.userMessage(from: source.id, to: .session(target.id)))
        let messageID = try #require(receipts.first?.messageID)
        try await backend.changes.wait(untilAtLeast: Self.firstCall) { backend.prompts.count }
        fixture.directory.emit(Self.marker)
        let beforeTheModelOutput = await Self.deliveries(through: &events).map(\.id)
        await latch.open()

        #expect(beforeTheModelOutput == [messageID])
        #expect(await target.awaitIdle())
        await fixture.close([source, target])
    }

    // MARK: - Queued

    /// A session that works in a held turn, and the fixture of the test.
    private struct HeldTurn {
        /// The latch that ends the turn when it opens.
        let latch: RunLatch

        /// The fixture of the test.
        let fixture: Fixture

        /// The working session.
        let target: any RoutedSession

        /// Opens the latch, waits until the target is idle, and closes the
        /// fixture.
        func end() async {
            await latch.open()
            #expect(await target.awaitIdle())
            await fixture.close([target])
        }
    }

    /// Starts a held turn on a new session of a new fixture
    /// (``RouterSessionDirectoryDeliveryTests/startHeldTurn(in:on:)``).
    ///
    /// - Returns: The latch of the turn, the fixture and the working session.
    /// - Throws: The errors of the fixture and of the turn.
    private static func startHeldTurn() async throws -> HeldTurn {
        let (latch, backend, fixture) = try await makeHeldFixture()
        let target = try await RouterSessionDirectoryDeliveryTests.startHeldTurn(in: fixture, on: backend)
        return HeldTurn(latch: latch, fixture: fixture, target: target)
    }

    /// Sends a UI message with ``text`` to the working session of `turn`.
    ///
    /// - Parameter turn: The held turn.
    /// - Returns: The id of the message, whose mail waits in the queue.
    /// - Throws: The errors of the send, or the `#require` failure when the
    ///   receipt is not `queued`.
    private static func sendQueued(in turn: HeldTurn) async throws -> MailID {
        let receipts = try await turn.fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: clientID), to: .session(turn.target.id), text: text))
        try #require(receipts.map(\.outcome) == [.queued])
        return try #require(receipts.first?.messageID)
    }

    /// The production change that makes this test fail: a send that gives
    /// the event when it puts the mail in the queue of a working target.
    @Test("a message to a working session gives no event while it waits in the queue")
    func aQueuedMessageGivesNoEventWhileItWaits() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()

        _ = try await Self.sendQueued(in: turn)
        turn.fixture.directory.emit(Self.marker)

        #expect(await Self.deliveries(through: &events).isEmpty)
        await turn.end()
    }

    /// The production change that makes this test fail: a queued message
    /// that gives no event when the end of the turn delivers it.
    @Test("a message to a working session gives its event when the turn ends")
    func aQueuedMessageGivesItsEventWhenTheTurnEnds() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()
        let messageID = try await Self.sendQueued(in: turn)

        await turn.latch.open()

        #expect(await events.nextDelivery(of: messageID)?.to == turn.target.id)
        await turn.end()
    }

    /// The production change that makes this test fail: an inbox read that
    /// gives no event for a waiting message, or a read and a later take that
    /// both give one.
    @Test("a waiting message that the inbox reads gives one event at the read")
    func aWaitingMessageThatTheInboxReadsGivesOneEvent() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()
        let messageID = try await Self.sendQueued(in: turn)

        _ = try await turn.fixture.directory.inbox(of: turn.target.id, markRead: true)
        await turn.latch.open()
        #expect(await turn.target.awaitIdle())
        turn.fixture.directory.emit(Self.marker)

        #expect(await Self.deliveries(through: &events).map(\.id) == [messageID])
        await turn.end()
    }

    /// The production change that makes this test fail: a cancelled mail
    /// whose message still gives an event.
    @Test("a waiting message whose mail is cancelled gives no event")
    func aCancelledMessageGivesNoEvent() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()
        let messageID = try await Self.sendQueued(in: turn)

        _ = turn.target.cancel(messageID)
        await #expect(throws: CancellationError.self) { try await turn.target.awaitAnswer(of: messageID) }
        await turn.latch.open()
        #expect(await turn.target.awaitIdle())
        turn.fixture.directory.emit(Self.marker)

        #expect(await Self.deliveries(through: &events).isEmpty)
        await turn.end()
    }
}
