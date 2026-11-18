import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The `messageQueued` event of ``RouterSessionDirectory`` (D199
/// follow-up): a send whose receipt is `queued` (a working target, whose
/// ledger keeps the message) or `sent` (a recorded target, whose inbox file
/// keeps it) gives `messageQueued` at the send, before the send returns its
/// receipt. `messageDelivered` of the same message comes later, one time,
/// when the target takes the message. A `delivered` or a `started` receipt
/// gives no `messageQueued`, and a refused message gives no event.
///
/// Each test emits ``marker`` after the send returns. Thus a
/// `messageQueued` event before ``marker`` in the feed came before the
/// receipt. Each test runs on the fixture of
/// ``RouterSessionDirectoryDeliveryTests``.
@Suite("RouterSessionDirectory: the messageQueued event of a message")
struct RouterSessionDirectoryQueuedEventTests {
    /// The fixture of each test.
    typealias Fixture = RouterSessionDirectoryDeliveryTests.Fixture

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    /// The agent of the test that starts a session.
    private static let agentID = "queued-event-agent"

    /// An event that no session sends. A test emits it after the send
    /// returns, and reads the events up to it.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// A second event that no session sends. A test emits it after the
    /// target took the message.
    private static let endMarker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// The message event of the feed that a test reads: the kind of the
    /// event and the id of its message.
    private enum MessageEvent: Equatable {
        /// A `messageQueued` event of the message with this id.
        case queued(MailID)

        /// A `messageDelivered` event of the message with this id.
        case delivered(MailID)
    }

    // MARK: - Helpers

    /// The message events up to `marker`, in stream order. The caller emits
    /// `marker` first.
    ///
    /// - Parameters:
    ///   - events: The event feed of the directory, opened before the send.
    ///   - marker: The event that ends the read.
    /// - Returns: The message events, with no other event.
    private static func messageEvents(
        through events: inout AsyncStream<SessionDirectoryEvent>.Iterator,
        upTo marker: SessionDirectoryEvent = marker
    ) async -> [MessageEvent] {
        await events.next(through: marker).compactMap(messageEvent(of:))
    }

    /// The message event of `event`.
    ///
    /// - Parameter event: An event of the feed.
    /// - Returns: The message event, or `nil` for an event that is not a
    ///   message event.
    private static func messageEvent(of event: SessionDirectoryEvent) -> MessageEvent? {
        switch event {
        case .messageQueued(let message):
            .queued(message.id)
        case .messageDelivered(let message):
            .delivered(message.id)
        case .started, .factsChanged, .stateChanged, .archived, .unarchived:
            nil
        }
    }

    /// The message events that `steps` gives on a new registry with one open
    /// stream, in stream order.
    ///
    /// - Parameter steps: The changes of the registry.
    /// - Returns: The message events, with no other event.
    private static func messageEvents(
        after steps: (inout RouterSessionDirectory.Registry) -> Void
    ) async -> [MessageEvent] {
        var registry = RouterSessionDirectory.Registry()
        let (stream, continuation) = SessionDirectoryEventFanout.makeStream()
        _ = registry.fanout.add(continuation)
        steps(&registry)
        continuation.finish()
        return await stream.compactMap(messageEvent(of:)).reduce(into: []) { $0.append($1) }
    }

    /// Puts `message` in the registry as a send of a `queued` receipt does
    /// before the mail put (``RouterSessionDirectory/hand(_:userHeader:to:ledger:isQueued:)``):
    /// it waits for its `messageQueued` event and for its delivery.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - registry: The registry.
    private static func wait(_ message: SessionMessage, in registry: inout RouterSessionDirectory.Registry) {
        registry.awaitingQueuedEvent[message.id] = message
        registry.awaitingDelivery[message.id] = message
    }

    /// A UI message with ``text`` to a new session id.
    ///
    /// - Returns: The message.
    private static func waitingMessage() -> SessionMessage {
        SessionMessage(
            id: MailID(), from: .user(clientID: clientID), to: ULID.generate(), text: text, sentAt: Date(),
            chainDepth: 0)
    }

    /// A session that works in a held turn, and the fixture of the test.
    private struct HeldTurn {
        /// The latch that ends the turn when it opens.
        let latch: RunLatch

        /// The fixture of the test.
        let fixture: Fixture

        /// The working session.
        let target: any RoutedSession

        /// Opens the latch, and waits until the target is idle.
        func open() async {
            await latch.open()
            #expect(await target.awaitIdle())
        }
    }

    /// Starts a held turn on a new session of a new fixture
    /// (``RouterSessionDirectoryDeliveryTests/startHeldTurn(in:on:)``).
    ///
    /// - Returns: The latch of the turn, the fixture and the working session.
    /// - Throws: The errors of the fixture and of the turn.
    private static func startHeldTurn() async throws -> HeldTurn {
        let latch = RunLatch()
        let backend = RouterSessionDirectoryDeliveryTests.Backend(script: [firstCall: .hold(latch)])
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let target = try await RouterSessionDirectoryDeliveryTests.startHeldTurn(in: fixture, on: backend)
        return HeldTurn(latch: latch, fixture: fixture, target: target)
    }

    /// Sends `message` and gives the id of its one receipt, which must have
    /// `outcome`.
    ///
    /// - Parameters:
    ///   - message: The message, to one target.
    ///   - outcome: The outcome that the receipt must have.
    ///   - fixture: The fixture of the test.
    /// - Returns: The id of the message.
    /// - Throws: The errors of the send, or the `#require` failure when the
    ///   receipt has another outcome.
    private static func send(
        _ message: OutgoingSessionMessage, expecting outcome: SessionSendReceipt.Outcome, in fixture: Fixture
    ) async throws -> MailID {
        let receipts = try await fixture.directory.send(message)
        try #require(receipts.map(\.outcome) == [outcome])
        return try #require(receipts.first?.messageID)
    }

    /// A UI message with ``text`` to the session `id`.
    ///
    /// - Parameter id: The session id of the target.
    /// - Returns: The message.
    private static func userMessage(to id: ULID) -> OutgoingSessionMessage {
        OutgoingSessionMessage(from: .user(clientID: clientID), to: .session(id), text: text)
    }

    // MARK: - Working target

    /// The production change that makes this test fail: a send to a working
    /// session that gives no `messageQueued`, or gives it after the receipt.
    @Test("a UI message to a working session gives messageQueued before the receipt returns")
    func aUserMessageToAWorkingSessionGivesMessageQueuedAtTheSend() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()

        let messageID = try await Self.send(
            Self.userMessage(to: turn.target.id), expecting: .queued, in: turn.fixture)
        turn.fixture.directory.emit(Self.marker)

        #expect(await Self.messageEvents(through: &events) == [.queued(messageID)])
        await turn.open()
        await turn.fixture.close([turn.target])
    }

    /// The production change that makes this test fail: a session message
    /// that goes to a working durable session as an inbox file, and gives no
    /// `messageQueued` before the receipt returns.
    @Test("a session message to a working durable session gives messageQueued before the receipt returns")
    func aSessionMessageToAWorkingSessionGivesMessageQueuedAtTheSend() async throws {
        let turn = try await Self.startHeldTurn()
        let sender = turn.fixture.makeSession()
        var events = turn.fixture.directory.events().makeAsyncIterator()
        let message = OutgoingSessionMessage(
            from: .session(sender.id), to: .session(turn.target.id), text: Self.text)

        let messageID = try await Self.send(message, expecting: .queued, in: turn.fixture)
        turn.fixture.directory.emit(Self.marker)

        #expect(await Self.messageEvents(through: &events) == [.queued(messageID)])
        await turn.open()
        await turn.fixture.close([sender, turn.target])
    }

    /// The production change that makes this test fail: a `messageDelivered`
    /// event that comes at the send, before the held turn ends, or a second
    /// `messageQueued` when the turn takes the message.
    ///
    /// The turn holds until the test opens its latch, so the target cannot
    /// take the message before ``marker``. The events after ``marker`` are
    /// thus the events of the take.
    @Test("a queued message gives messageDelivered only when the held turn ends")
    func aQueuedMessageGivesMessageDeliveredWhenTheTurnEnds() async throws {
        let turn = try await Self.startHeldTurn()
        var events = turn.fixture.directory.events().makeAsyncIterator()
        let messageID = try await Self.send(
            Self.userMessage(to: turn.target.id), expecting: .queued, in: turn.fixture)
        turn.fixture.directory.emit(Self.marker)
        let atTheSend = await Self.messageEvents(through: &events)

        await turn.open()
        turn.fixture.directory.emit(Self.endMarker)

        #expect(atTheSend == [.queued(messageID)])
        #expect(await Self.messageEvents(through: &events, upTo: Self.endMarker) == [.delivered(messageID)])
        await turn.fixture.close([turn.target])
    }

    // MARK: - Recorded target

    /// The production change that makes this test fail: a send to a recorded
    /// session that gives no `messageQueued` before the receipt returns, or
    /// that gives `messageDelivered` before a host opens the session.
    @Test("a message to a recorded session gives messageQueued at the send, and no messageDelivered")
    func aMessageToARecordedSessionGivesMessageQueuedAtTheSend() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let id = try await fixture.recordClosedSession()
        let sender = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()
        let message = OutgoingSessionMessage(from: .session(sender.id), to: .session(id), text: Self.text)

        let messageID = try await Self.send(message, expecting: .sent, in: fixture)
        fixture.directory.emit(Self.marker)

        #expect(await Self.messageEvents(through: &events) == [.queued(messageID)])
        await fixture.close([sender])
    }

    // MARK: - Delivered and started

    /// The production change that makes this test fail: a `messageQueued`
    /// event for a message that an idle session takes at once, or a second
    /// `messageDelivered`.
    ///
    /// The order that the test expects: one `messageDelivered`, and no
    /// `messageQueued`, because the idle target takes the message at once.
    @Test("a message to an idle session gives one messageDelivered and no messageQueued")
    func aMessageToAnIdleSessionGivesOnlyMessageDelivered() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let target = fixture.makeSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.sendAndAwaitDelivery(Self.userMessage(to: target.id))
        #expect(await target.awaitIdle())
        fixture.directory.emit(Self.marker)

        let messageID = try #require(receipts.first?.messageID)
        #expect(await Self.messageEvents(through: &events) == [.delivered(messageID)])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a `messageQueued`
    /// event for the first message of a session that a send starts.
    @Test("a message that starts an agent session gives one messageDelivered and no messageQueued")
    func aMessageThatStartsASessionGivesOnlyMessageDelivered() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        var events = fixture.directory.events().makeAsyncIterator()
        let message = OutgoingSessionMessage(
            from: .user(clientID: Self.clientID), to: .agent(id: Self.agentID, folder: nil), text: Self.text)

        let receipts = try await fixture.directory.sendAndAwaitDelivery(message)
        let started = try #require(fixture.launcher.sessions.first)
        #expect(await started.awaitIdle())
        fixture.directory.emit(Self.marker)

        let messageID = try #require(receipts.first?.messageID)
        #expect(await Self.messageEvents(through: &events) == [.delivered(messageID)])
        await fixture.close([])
    }

    // MARK: - Refused

    /// The production change that makes this test fail: a refused send to an
    /// archived session that gives a message event.
    @Test("a message to an archived session is refused and gives no message event")
    func aRefusedMessageGivesNoEvent() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let id = try await fixture.recordClosedSession { $0.archivedAt = Date() }
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(Self.userMessage(to: id))
        fixture.directory.emit(Self.marker)

        #expect(receipts.map(\.outcome) == [.refused])
        #expect(await Self.messageEvents(through: &events).isEmpty)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a UI message with no
    /// source session to a recorded session, which the directory refuses,
    /// that gives a `messageQueued` event.
    @Test("a UI message with no source session to a recorded session is refused and gives no message event")
    func aRefusedMessageToARecordedSessionGivesNoEvent() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let id = try await fixture.recordClosedSession()
        var events = fixture.directory.events().makeAsyncIterator()

        let receipts = try await fixture.directory.send(Self.userMessage(to: id))
        fixture.directory.emit(Self.marker)

        #expect(receipts.map(\.outcome) == [.refused])
        #expect(await Self.messageEvents(through: &events).isEmpty)
        await fixture.close([])
    }

    // MARK: - Registry

    /// The production change that makes this test fail: a `sendDelivered`
    /// that does not send the `messageQueued` event that waits, so a pump
    /// that takes the mail before the send sends `messageQueued` gives
    /// `messageDelivered` first.
    @Test("a take of the mail before the queued event gives messageQueued, then messageDelivered")
    func aTakeBeforeTheQueuedEventGivesMessageQueuedFirst() async {
        let message = Self.waitingMessage()

        let events = await Self.messageEvents { registry in
            Self.wait(message, in: &registry)
            registry.sendDelivered(message.id)
            registry.sendQueued(message.id)
        }

        #expect(events == [.queued(message.id), .delivered(message.id)])
    }

    /// The production change that makes this test fail: a `cancelledOrLost`
    /// fate that removes the `messageQueued` event that waits, so a target
    /// that cancels or loses the mail during the send gives a `queued`
    /// receipt with no `messageQueued`.
    @Test("a cancelled or lost mail during the send still gives one messageQueued")
    func aCancelledOrLostMailDuringTheSendGivesOneMessageQueued() async {
        let message = Self.waitingMessage()

        let events = await Self.messageEvents { registry in
            Self.wait(message, in: &registry)
            registry.apply(.cancelledOrLost(message.id))
            registry.sendQueued(message.id)
        }

        #expect(events == [.queued(message.id)])
    }

    /// The production change that makes this test fail: a refused mail that
    /// keeps the `messageQueued` event or the `messageDelivered` event of its
    /// message.
    @Test("a refused mail gives no message event")
    func aRefusedMailGivesNoMessageEvent() async {
        let message = Self.waitingMessage()

        let events = await Self.messageEvents { registry in
            Self.wait(message, in: &registry)
            registry.forgetRefusedMail(message.id)
            registry.sendDelivered(message.id)
            registry.sendQueued(message.id)
        }

        #expect(events.isEmpty)
    }
}
