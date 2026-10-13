import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the output side of the mail queue of a session (`mailbox.md`,
/// section 5): the subscription that ``RoutedSession/mail(_:)`` gives, its
/// refusals, the waits for a terminal event, the elicitation answer mail,
/// and the output of a guided session.
///
/// ``SessionOutputHub`` gives each output to the feeds and to the mail
/// subscriptions, and keeps a ledger of the terminal events of the most
/// recent ids. The hub tests call the hub directly. The session tests run on
/// ``SessionMessagePumpTests/PumpProbeBackend`` through
/// ``MailQueueFixtures``. The suite needs no network and no GPU.
@Suite("The mail subscription, the refusals and the terminal waits of a session")
struct MailSubscriptionTests {
    /// The backend the suite scripts.
    private typealias Backend = MailQueueFixtures.Backend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "MailSubscriptionTests"

    /// The prompt of the message whose submission the test holds open.
    private static let heldPrompt = "held question"

    /// The prompt of the first queued message.
    private static let firstPrompt = "first queued question"

    /// The prompt of the second queued message.
    private static let secondPrompt = "second queued question"

    /// A token ceiling that keeps a message out of the batch of a message
    /// with no ceiling.
    private static let namedCeiling = 100

    /// The time a test gives a wait to return when the wait must not
    /// return. The test uses it only to prove that something does not
    /// happen.
    private static let noReturnWindow = Duration.milliseconds(100)

    /// The grammar of the guided session.
    private static let grammar = Grammar.jsonSchema(#"{"type":"string"}"#)

    /// Records that a task ended, so a test reads it with no wait.
    private final class EndMark: Sendable {
        /// Whether the task ended.
        private let ended = Mutex(false)

        /// Records that the task ended.
        func mark() {
            ended.withLock { $0 = true }
        }

        /// Whether the task ended.
        var isMarked: Bool {
            ended.withLock { $0 }
        }
    }

    // MARK: - Fixtures

    /// Starts an answer for ``heldPrompt`` on a backend that a latch holds
    /// open, and waits until its submission reached the backend.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - backend: The backend of the session.
    /// - Returns: The id of the held message.
    /// - Throws: When the submission does not reach the backend inside the
    ///   bound.
    private static func startHeldAnswer(on session: any RoutedSession, backend: Backend) async throws -> MailID {
        let held = try session.send(heldPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        return held
    }

    /// A user message in reply mode.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - maxTokens: The token ceiling, or `nil`.
    /// - Returns: The mail, with a new id.
    private static func reply(_ prompt: String, maxTokens: Int? = nil) -> Mail {
        RoutedSessionActor.userMessage(prompt, maxTokens: maxTokens, mode: .reply)
    }

    /// Reads `feed` to its end. Call it after ``RoutedSession/close()``,
    /// which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each event the feed delivered, in order.
    private static func events(of feed: AsyncStream<SessionOutput>) async -> [SessionEvent] {
        await collect(feed.events)
    }

    /// A failed compaction whose id is the signal `signal`.
    ///
    /// - Parameter signal: The id of the signal.
    /// - Returns: The failure.
    private static func compactionFailure(of signal: SignalID) -> CompactionFailure {
        CompactionFailure(id: signal.description, reason: .triggerReached, outcome: .cancelled)
    }

    // MARK: - The refusals of mail(_:)

    @Test("mail(_:) refuses an id that is in the queue with duplicateID, and the first mail goes on to its answer")
    func mailRefusesAQueuedID() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let queued = Self.reply(Self.firstPrompt)
        let subscription = try session.mail(queued)
        #expect(throws: MailRefusal.duplicateID(queued.id)) {
            _ = try session.mail(queued)
        }
        #expect(session.outbox.queue.pending.map(\.id) == [queued.id])
        await latch.open()
        let outputs = await MailQueueFixtures.readToEnd(subscription)
        #expect(await session.becomesIdle())
        await session.close()

        let end = try #require(outputs.last)
        #expect(MailQueueFixtures.answer(of: end.event)?.mailIds == [queued.id])
        #expect(backend.prompts == [Self.heldPrompt, Self.firstPrompt])
        TerminalEventLedger(events: await Self.events(of: feed)).expectExactlyOneTerminal(for: [held, queued.id])
        withExtendedLifetime(profile) {}
    }

    @Test("mail(_:) refuses an id that the open answer carries with duplicateID")
    func mailRefusesAnIDOfTheOpenAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let running = Self.reply(Self.heldPrompt)
        let subscription = try session.mail(running)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let copy = Mail(
            id: running.id, sender: .user,
            body: .userMessage(prompt: Self.firstPrompt, options: UserMessageOptions()))
        #expect(throws: MailRefusal.duplicateID(running.id)) {
            _ = try session.mail(copy)
        }
        #expect(session.outbox.queue.pending.isEmpty)
        await latch.open()
        let outputs = await MailQueueFixtures.readToEnd(subscription)
        #expect(await session.becomesIdle())
        await session.close()

        let end = try #require(outputs.last)
        #expect(MailQueueFixtures.answer(of: end.event)?.mailIds == [running.id])
        #expect(backend.prompts == [Self.heldPrompt])
        TerminalEventLedger(events: await Self.events(of: feed)).expectExactlyOneTerminal(for: [running.id])
        withExtendedLifetime(profile) {}
    }

    @Test("after close(), mail(_:) and send(_:) throw closed")
    func mailAndSendRefuseAfterClose() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)

        await session.close()
        #expect(throws: MailRefusal.closed) {
            _ = try session.mail(Self.reply(Self.firstPrompt))
        }
        #expect(throws: MailRefusal.closed) {
            try session.send(Self.secondPrompt)
        }
        #expect(session.outbox.queue.pending.isEmpty)
        #expect(backend.prompts.isEmpty)
        withExtendedLifetime(profile) {}
    }

    // MARK: - The subscription of mail(_:)

    @Test("a subscription gets each output of its mail up to and including its terminal event, then finishes, with no output of other mail")
    func aSubscriptionGetsTheOutputOfItsMailOnly() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let watched = Self.reply(Self.firstPrompt)
        let subscription = try session.mail(watched)
        // Another ceiling, so the next mail is an answer of its own after
        // the answer of the watched mail.
        let later = Self.reply(Self.secondPrompt, maxTokens: Self.namedCeiling)
        _ = try session.mail(later)
        let reading = Task { await MailQueueFixtures.readToEnd(subscription) }
        await latch.open()
        let outputs = await reading.value
        #expect(await session.becomesIdle())
        await session.close()

        #expect(outputs.allSatisfy { $0.origin == .mail([watched.id]) }, "\(outputs)")
        #expect(outputs.first?.event == .mailDelivered(watched.id))
        #expect(outputs.contains { MailQueueFixtures.isSubmissionStart($0.event) })
        let end = try #require(outputs.last)
        #expect(MailQueueFixtures.answer(of: end.event)?.mailIds == [watched.id])
        #expect(TerminalEventLedger(outputs: outputs).endedMailIds == [[watched.id]])
        let events = await Self.events(of: feed)
        #expect(events.answers.map(\.mailIds) == [[held], [watched.id], [later.id]])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [held, watched.id, later.id])
        withExtendedLifetime(profile) {}
    }

    // MARK: - The waits for a terminal event

    @Test("awaitTerminal(of: MailID) waits for a terminal that has not come, and returns at once from the ledger after it came")
    func awaitTerminalOfMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let hub = (session as! RoutedSessionActor).outputHub

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let mark = EndMark()
        let waiting = Task {
            defer { mark.mark() }
            return try await session.awaitTerminal(of: held)
        }
        // The latch is shut, so no terminal can come. A short wait proves
        // that the call does not return.
        try await Task.sleep(for: Self.noReturnWindow)
        #expect(!mark.isMarked)
        #expect(hub.terminal(for: .mail(held)) == nil)
        await latch.open()
        let terminal = try await waiting.value

        #expect(MailQueueFixtures.answer(of: terminal)?.mailIds == [held])
        #expect(hub.terminal(for: .mail(held))?.event == terminal)
        #expect(try await session.awaitTerminal(of: held) == terminal)
        await session.close()
        // The ledger keeps the terminal after the close too.
        #expect(try await session.awaitTerminal(of: held) == terminal)
        withExtendedLifetime(profile) {}
    }

    @Test("awaitTerminal(of: SignalID) returns the compaction end whose id is the signal id, and returns at once after it came")
    func awaitTerminalOfSignal() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let actor = session as! RoutedSessionActor

        let signal = SignalID()
        let waiting = Task { try await session.awaitTerminal(of: signal) }
        // The end of another signal does not end the wait.
        actor.emitSessionScopedEvent(.compactionFailed(Self.compactionFailure(of: SignalID())))
        actor.emitSessionScopedEvent(.compactionFailed(Self.compactionFailure(of: signal)))

        let expected = SessionEvent.compactionFailed(Self.compactionFailure(of: signal))
        #expect(try await waiting.value == expected)
        #expect(try await session.awaitTerminal(of: signal) == expected)
        await session.close()
        withExtendedLifetime(profile) {}
    }

    // MARK: - The elicitation answer mail

    @Test("respond(elicitationId:response:) that delivers also queues one elicitationAnswer mail, which starts an answer")
    func aDeliveredElicitationAnswerStartsAnAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let elicitationId = ULID.generate()
        let context = ToolContext(
            sessionID: session.id, runPlane: session.mailbox, sink: DiscardingOperationEventSink(),
            tool: MailQueueFixtures.runTool, op: MailQueueFixtures.runOp,
            completionToken: RunPlane.makeCompletionToken(), isCancelled: { false })
        let answering = AnswerDrivenRun(waitingFor: "the elicitation \(elicitationId)") {
            try await context.elicit(PendingElicitationFixtures.formRequest(elicitationId: elicitationId))
        }
        #expect(
            await BoundedWait.conditionReached("the elicitation \(elicitationId) pending") {
                await session.mailbox.pendingElicitationIds().contains(elicitationId)
            })
        #expect(backend.prompts.isEmpty)

        let response = ElicitationResponse.accept(content: ["name": .string("Ada")])
        #expect(await session.respond(elicitationId: elicitationId.description, response: response) == .delivered)
        #expect(try await answering.deliveredAnswer() == response)
        #expect(await session.becomesIdle())
        await session.close()

        #expect(backend.prompts.count == 1)
        #expect(backend.prompts.first?.hasPrefix("[answer to elicitation \(elicitationId.ulidString)] accept:") == true)
        let events = await Self.events(of: feed)
        let answer = try #require(events.answers.first)
        #expect(events.answers.count == 1)
        #expect(answer.mailIds.count == 1)
        #expect(events.submissionStarts.map(\.cause) == [.message])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: answer.mailIds)
        withExtendedLifetime(profile) {}
    }

    // MARK: - A guided session

    @Test("a guided session sends no textDelta for a stream message, and streamResponse gives the reply once")
    func aGuidedSessionDoesNotStream() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(
            over: backend, dir: dir, grammar: Self.grammar)

        let events = try await collect(session.streamEvents(to: Self.firstPrompt))
        #expect(events.streamedText.isEmpty)
        #expect(events.answers.map(\.reply) == [Backend.answer(ofCall: 1)])

        var pieces: [String] = []
        let response = await session.streamResponse(to: Self.secondPrompt)
        for try await piece in response {
            pieces.append(piece)
        }
        #expect(pieces == [Backend.answer(ofCall: 2)])
        #expect(backend.prompts == [Self.firstPrompt, Self.secondPrompt])
        await session.close()
        withExtendedLifetime(profile) {}
    }

    // MARK: - The output hub

    @Test("the hub keeps at most ledgerCapacity terminal ids, and the oldest id leaves first")
    func theLedgerDropsTheOldestID() throws {
        let hub = SessionOutputHub()
        let ids = (0...SessionOutputHub.ledgerCapacity).map { _ in MailID() }
        for id in ids {
            hub.emit(SessionOutput(origin: .mail([id]), event: .cancelled(id)))
        }

        let oldest = try #require(ids.first)
        let newest = try #require(ids.last)
        #expect(hub.terminal(for: .mail(oldest)) == nil)
        #expect(hub.terminal(for: .mail(ids[1]))?.event == .cancelled(ids[1]))
        #expect(hub.terminal(for: .mail(newest))?.event == .cancelled(newest))
    }

    @Test("a hub subscription gets the output whose origin holds its id, up to its terminal event, and then finishes")
    func aHubSubscriptionEndsAtItsTerminal() async {
        let hub = SessionOutputHub()
        let watched = MailID()
        let other = MailID()
        let (subscription, _) = hub.subscribe(to: watched)

        hub.emit(SessionOutput(origin: .mail([other]), event: .mailDelivered(other)))
        hub.emit(SessionOutput(origin: .mail([watched, other]), event: .mailDelivered(watched)))
        hub.emit(SessionOutput(origin: .mail([watched]), event: .cancelled(watched)))
        hub.emit(SessionOutput(origin: .mail([watched]), event: .mailDelivered(watched)))

        let outputs = await MailQueueFixtures.readToEnd(subscription)
        #expect(outputs.map(\.event) == [.mailDelivered(watched), .cancelled(watched)])
    }

    @Test("a hub wait for a signal ends with the compaction end of that signal, and a close ends each other wait with closed")
    func hubWaitsForASignalAndEndsOnClose() async throws {
        let hub = SessionOutputHub()
        let signal = SignalID()
        let failure = Self.compactionFailure(of: signal)

        let signalWait = Task { try await hub.awaitTerminal(of: .signal(signal.description)).event }
        hub.emit(SessionOutput(origin: .signal(signal), event: .compactionFailed(failure)))
        #expect(try await signalWait.value == .compactionFailed(failure))

        let mailWait = Task { try await hub.awaitTerminal(of: .mail(MailID())).event }
        hub.close()
        await #expect(throws: MailRefusal.closed) {
            _ = try await mailWait.value
        }
        // The ledger keeps the terminal of the signal after the close.
        #expect(try await hub.awaitTerminal(of: .signal(signal.description)).event == .compactionFailed(failure))
    }
}
