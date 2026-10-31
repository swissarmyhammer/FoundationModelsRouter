import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The delivery rules of ``RouterSessionDirectory/send(_:)`` (ROUTER-5): an
/// idle target starts a turn (`delivered`); a working target, or one that
/// needs input, gets the mail in its own mail queue, where it waits for the
/// end of the turn (`queued`); a message that `inbox(of:markRead: true)`
/// reads before its delivery leaves the queue and starts no turn; a recorded
/// target that is not live gets a file in its inbox and the receipt `sent`,
/// with no call to the launcher; an archived target is refused and never
/// restored.
///
/// Each test runs on a router that records to a durable root, with a
/// ``FakeSessionLauncher`` over its scripted profile. A latch of a
/// ``SessionMessagePumpTests/PumpProbeBackend`` holds a turn open where a
/// test sends while the target works.
@Suite("RouterSessionDirectory: the delivery rules of a message")
struct RouterSessionDirectoryDeliveryTests {
    /// The backend the scripted-turn tests drive.
    typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// A router over a durable recordings root, and a launcher over its
    /// profile.
    struct Fixture {
        /// The cache and recordings folders of the test.
        let directories: TestDirectories

        /// The router whose directory is under test.
        let router: Router

        /// The resolved profile of ``router``.
        let profile: LanguageModelProfile

        /// The launcher of the directory.
        let launcher: FakeSessionLauncher

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Vends a root session of ``router``. The caller holds it.
        ///
        /// - Parameter configuration: The configuration of the session.
        /// - Returns: The session, live in ``directory``.
        func makeSession(_ configuration: SessionConfiguration = SessionConfiguration()) -> any RoutedSession {
            profile.standard.makeSession(configuration: configuration)
        }

        /// Records a closed root session that is not live, and gives the
        /// directory its recording root, so the session answers as recorded.
        ///
        /// - Parameter facts: A change of the facts of the session before it
        ///   closes. The default changes nothing.
        /// - Returns: The id of the recorded session.
        /// - Throws: The `#require` failure when the vended session is not a
        ///   ``RoutedSessionActor``.
        func recordClosedSession(changingFacts facts: (inout SessionFacts) -> Void = { _ in }) async throws -> ULID {
            try await recordClosedSessionWithFolder(changingFacts: facts).id
        }

        /// Records a closed root session as ``recordClosedSession(changingFacts:)``
        /// does, and also gives the session folder.
        ///
        /// - Parameter facts: A change of the facts of the session before it
        ///   closes. The default changes nothing.
        /// - Returns: The id and the session folder of the recorded session.
        /// - Throws: The `#require` failure when the vended session is not a
        ///   ``RoutedSessionActor``.
        func recordClosedSessionWithFolder(
            changingFacts facts: (inout SessionFacts) -> Void = { _ in }
        ) async throws -> (id: ULID, folder: URL) {
            let recorded = try #require(makeSession() as? RoutedSessionActor)
            recorded.updateFacts(facts)
            let root = recorded.recordingDirectory.deletingLastPathComponent()
            await recorded.close()
            await directory.useRecordingRoots { [root] }
            return (recorded.id, recorded.recordingDirectory)
        }

        /// Closes `sessions` and each session of ``launcher``, and removes the
        /// folders of the test.
        ///
        /// - Parameter sessions: The sessions the test vended.
        func close(_ sessions: [any RoutedSession]) async {
            for session in sessions {
                await session.close()
            }
            await launcher.closeSessions()
            directories.remove()
        }
    }

    // MARK: - Constants

    /// The prompt that starts the turn a test holds open.
    private static let turnPrompt = "first question"

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The text of the second message that waits for the end of a turn.
    private static let secondText = "Please also check the tests."

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    /// The events of a vend and of one held turn up to the state of the
    /// turn: `started`, then `stateChanged` to working.
    private static let eventsUpToTheTurn = 2

    /// More sessions than the old limit of four sessions that work at the
    /// same time (D72), so a delivery that waited for a slot would show.
    private static let sessionsAboveTheOldLimit = 5

    /// The tag of each session of the test with many sessions.
    private static let tag = "triage"

    /// A launcher that fails the test at each call, and throws, so a send
    /// that reaches the launcher shows at once.
    private struct UncalledLauncher: SessionLauncher {
        /// The error of each call.
        private struct Called: Error {}

        /// Fails the test: a send never starts a session.
        func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
            Issue.record("The directory started a session for a send to a recorded session.")
            throw Called()
        }

        /// Fails the test: a send never restores a session.
        func restoreSession(id: ULID) async throws -> any RoutedSession {
            Issue.record("The directory restored the recorded session \(id) for a send.")
            throw Called()
        }
    }

    // MARK: - Helpers

    /// Makes a fixture over `container`, whose directory uses a launcher
    /// over its profile.
    ///
    /// - Parameter container: The container that vends the backend of each
    ///   session.
    /// - Returns: The fixture.
    static func makeFixture(over container: any LoadedLLMContainer = BasicLLMContainer()) async throws -> Fixture {
        let directories = TestDirectories(prefix: "RouterSessionDirectoryDeliveryTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let launcher = FakeSessionLauncher(profile: profile)
        await router.sessionDirectory.use(launcher: launcher)
        return Fixture(directories: directories, router: router, profile: profile, launcher: launcher)
    }

    /// Sends one UI message with `text` to the session `id`, and waits until
    /// the directory delivered it (``RouterSessionDirectory/sendAndAwaitDelivery(_:)``):
    /// a send to a durable session goes through an inbox file, and the mail
    /// and the ledger of the target follow the receipt.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - id: The session id of the target.
    ///   - fixture: The fixture of the test.
    /// - Returns: The receipts of the send.
    private static func send(
        _ text: String = text, to id: ULID, in fixture: Fixture
    ) async throws -> [SessionSendReceipt] {
        try await fixture.directory.sendAndAwaitDelivery(text, fromClient: clientID, to: id)
    }

    /// Starts a held turn on a new session: vends it, sends it the turn
    /// prompt, reads the directory events up to its `stateChanged` to
    /// working, and waits until the held call of the turn took the prompt,
    /// so a later mail cannot join the prompt of that call.
    ///
    /// - Parameters:
    ///   - fixture: A fixture over `backend`.
    ///   - backend: The backend of the fixture, whose first call holds.
    /// - Returns: The working session.
    /// - Throws: The refusal of the turn prompt, or ``ConditionNeverHeld``
    ///   when the test is cancelled before the call starts.
    static func startHeldTurn(in fixture: Fixture, on backend: Backend) async throws -> any RoutedSession {
        var events = fixture.directory.events().makeAsyncIterator()
        let session = fixture.makeSession()
        _ = try session.send(turnPrompt)
        let upToTheTurn = await events.next(count: eventsUpToTheTurn)
        try await backend.changes.wait(untilAtLeast: firstCall) { backend.prompts.count }
        #expect(upToTheTurn.last == .stateChanged(id: session.id, state: .working, lastSummary: nil))
        return session
    }

    /// The ids of the mail that waits in the mail queue of `session`.
    ///
    /// - Parameter session: A live session.
    /// - Returns: The ids, in queue order.
    static func pendingIDs(of session: any RoutedSession) async -> [MailID] {
        await session.pendingMessages().map(\.id)
    }

    // MARK: - Idle

    /// The production change that makes this test fail: a send that puts
    /// no mail in the queue of an idle target, or a receipt other than
    /// `delivered` for it.
    @Test("a send to an idle session is delivered, and the scripted model answers it")
    func aSendToAnIdleSessionIsDeliveredAndAnswered() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()

        let receipts = try await Self.send(to: target.id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        #expect(await target.awaitIdle())
        let transcript = await target.transcript
        #expect(transcript.promptTexts == [Self.text])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a limit on the
    /// sessions that work at the same time, which would queue a message to
    /// an idle session for want of a slot.
    @Test("a tag send to more sessions than the old limit is delivered to each")
    func noDeliveryWaitsForAFreeSlot() async throws {
        let fixture = try await Self.makeFixture()
        let targets = (0..<Self.sessionsAboveTheOldLimit).map { _ in
            fixture.makeSession(SessionConfiguration(tags: [Self.tag]))
        }

        let receipts = try await fixture.directory.sendAndAwaitDelivery(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .tag(Self.tag), text: Self.text))

        #expect(receipts.map(\.target) == targets.map(\.id).sorted())
        #expect(receipts.allSatisfy { $0.outcome == .delivered })
        await fixture.close(targets)
    }

    // MARK: - Working and needs input

    /// The production change that makes this test fail: a `delivered`
    /// receipt for a working target, or a message that starts a second turn
    /// of its own instead of riding one turn with the other waiting message.
    @Test("a send to a working session is queued in its mail queue, and the waiting messages start one turn after the turn ends")
    func aSendToAWorkingSessionIsQueuedUntilTheTurnEnds() async throws {
        let latch = RunLatch()
        let backend = Backend(script: [Self.firstCall: .hold(latch)])
        let fixture = try await Self.makeFixture(over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let target = try await Self.startHeldTurn(in: fixture, on: backend)

        let first = try await Self.send(to: target.id, in: fixture)
        let second = try await Self.send(Self.secondText, to: target.id, in: fixture)
        let waiting = await Self.pendingIDs(of: target)
        let promptsDuringTheTurn = backend.prompts
        await latch.open()

        let firstID = try #require(first.first?.messageID)
        let secondID = try #require(second.first?.messageID)
        #expect(first == [SessionSendReceipt(messageID: firstID, target: target.id, outcome: .queued)])
        #expect(second == [SessionSendReceipt(messageID: secondID, target: target.id, outcome: .queued)])
        #expect(waiting == [firstID, secondID])
        #expect(promptsDuringTheTurn == [Self.turnPrompt])
        #expect(await target.awaitIdle())
        #expect(backend.prompts == [Self.turnPrompt, Self.text + RoutedSessionActor.messageSeparator + Self.secondText])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a rule that reads
    /// only `working` as busy, so a target that waits for an answer gets
    /// `delivered`.
    @Test("a send to a session that needs input is queued")
    func aSendToASessionThatNeedsInputIsQueued() async throws {
        let askGate = RunLatch()
        let returnGate = RunLatch()
        let fixture = try await BackgroundingSessionFixture.make(
            prefix: "RouterSessionDirectoryDeliveryTests",
            tools: [SessionWorkEventTests.AskingTool(asksForURL: false, askGate: askGate, returnGate: returnGate)])
        try await fixture.endingAfter(opening: [askGate, returnGate]) {
            let directory = fixture.router.sessionDirectory
            var events = directory.events().makeAsyncIterator()
            var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
            let id = fixture.session.id
            _ = try await SessionWorkEventTests.outputsUpToTheQuestion(of: fixture, askGate: askGate, feed: &feed)
            // Rule T1 quiet state: a directory that never reports needsInput
            // hangs here, and the test never passes.
            while let event = await events.next(), event != .stateChanged(id: id, state: .needsInput, lastSummary: nil) {
                continue
            }

            let receipts = try await directory.sendAndAwaitDelivery(Self.text, fromClient: Self.clientID, to: id)

            let messageID = try #require(receipts.first?.messageID)
            #expect(receipts == [SessionSendReceipt(messageID: messageID, target: id, outcome: .queued)])
        }
    }

    // MARK: - Read messages

    /// The production change that makes this test fail: an inbox that marks
    /// the message read and leaves its mail in the queue of the session,
    /// so the mail starts a second turn when the held turn ends.
    @Test("a message that inbox marks read while the target works starts no turn")
    func aMessageMarkedReadDuringTheTurnStartsNoTurn() async throws {
        let latch = RunLatch()
        let backend = Backend(script: [Self.firstCall: .hold(latch)])
        let fixture = try await Self.makeFixture(over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let target = try await Self.startHeldTurn(in: fixture, on: backend)
        let messageID = try #require(try await Self.send(to: target.id, in: fixture).first?.messageID)

        let inbox = try await fixture.directory.inbox(of: target.id, markRead: true)
        // The signals of a session run in arrival order, so the end of this
        // later signal comes after the work of each signal the inbox sent.
        _ = try await target.awaitTerminal(of: target.cancel(MailID()))
        await latch.open()

        #expect(inbox.map(\.id) == [messageID])
        #expect(await target.awaitIdle())
        #expect(try await target.awaitTerminal(of: messageID) == .cancelled(messageID))
        #expect(backend.prompts == [Self.turnPrompt])
        #expect(try await fixture.directory.message(messageID, to: target.id)?.isRead == true)
        await fixture.close([target])
    }

    // MARK: - Recorded

    /// The production change that makes this test fail: a send to a recorded
    /// session that restores it through the launcher, or a receipt other
    /// than `sent`, or no file in the inbox of the session.
    @Test("a send to a recorded session writes one inbox file, answers sent, and the launcher gets no call")
    func aRecordedSessionGetsAFileAndTheReceiptIsSent() async throws {
        let fixture = try await Self.makeFixture()
        let (id, folder) = try await fixture.recordClosedSessionWithFolder()
        await fixture.directory.use(launcher: UncalledLauncher())

        let receipts = try await Self.send(to: id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: id, outcome: .sent)])
        #expect(try SessionInboxFile.pending(in: folder).map(\.lastPathComponent) == ["\(messageID).md"])
        #expect(try await fixture.directory.summary(of: id)?.isLive == false)
        await fixture.close([])
    }

    /// The production change that makes this test fail: a send to a
    /// recorded session that needs the launcher, so it throws `noLauncher`
    /// from a directory with none.
    @Test("a send to a recorded session needs no launcher")
    func aSendToARecordedSessionNeedsNoLauncher() async throws {
        let fixture = try await Self.makeFixture()
        let id = try await fixture.recordClosedSession()
        await fixture.directory.shutdown()

        let receipts = try await Self.send(to: id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: id, outcome: .sent)])
        await fixture.close([])
    }

    // MARK: - Archived

    /// The production change that makes this test fail: a send that
    /// restores an archived session.
    @Test("a send to an archived session is refused as archived, and the launcher gets no call")
    func anArchivedSessionIsRefusedAndNotRestored() async throws {
        let fixture = try await Self.makeFixture()
        let id = try await fixture.recordClosedSession { $0.archivedAt = Date() }

        let receipts = try await Self.send(to: id, in: fixture)

        #expect(
            receipts == [SessionSendReceipt(target: id, outcome: .refused, reason: SessionAddressResolution.archivedReason)]
        )
        #expect(fixture.launcher.restoredIDs.isEmpty)
        #expect(fixture.launcher.requests.isEmpty)
        await fixture.close([])
    }
}
