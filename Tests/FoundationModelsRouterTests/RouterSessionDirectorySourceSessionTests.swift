import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The header of a message from the user that names its source session
/// (D199 (f)): ``RouterSessionDirectory/send(_:)`` keeps the message a user
/// message, and starts its prompt with the line
/// `From the user, in <title> (<folder>)`, a blank line and the text.
///
/// Each test runs on the fixture of ``RouterSessionDirectoryDeliveryTests``:
/// a router that records to a durable root, with a launcher over its
/// scripted profile.
@Suite("RouterSessionDirectory: the source-session header of a user message")
struct RouterSessionDirectorySourceSessionTests {
    /// The fixture of each test.
    typealias Fixture = RouterSessionDirectoryDeliveryTests.Fixture

    /// The text of each message.
    private static let text = "Please review the open pull request."

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The title of a recorded source session.
    private static let recordedTitle = "Release notes"

    /// The agent of the test that starts a session.
    private static let agentID = "source-header-agent"

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    // MARK: - Helpers

    /// The prompt that a user message with `text` gets when it names a
    /// source session with `title` in `folder`.
    ///
    /// - Parameters:
    ///   - title: The name of the source session in the header.
    ///   - folder: The working folder of the source session.
    /// - Returns: The header line, a blank line and the text.
    private static func prompt(title: String, folder: URL) -> String {
        "From the user, in \(title) (\(folder.path))\n\n\(text)"
    }

    /// The prompt that a user message gets when it names the source session
    /// `id` with the title and the folder of its summary in the directory.
    ///
    /// - Parameters:
    ///   - id: The source session.
    ///   - fixture: The fixture of the test.
    /// - Returns: The expected prompt.
    /// - Throws: The `#require` failure when the directory has no summary of
    ///   `id`, or the summary has no title.
    private static func prompt(namingSource id: ULID, in fixture: Fixture) async throws -> String {
        let summary = try #require(try await fixture.directory.summary(of: id))
        return prompt(title: try #require(summary.title), folder: summary.workingDirectory)
    }

    /// Sends a user message with ``text`` and the source session `source` to
    /// `address`, and waits until the directory delivered it.
    ///
    /// - Parameters:
    ///   - address: The target of the message.
    ///   - source: The source session of the message.
    ///   - fixture: The fixture of the test.
    /// - Returns: The receipts of the send.
    private static func send(
        to address: SessionAddress, from source: ULID, in fixture: Fixture
    ) async throws -> [SessionSendReceipt] {
        try await fixture.directory.sendAndAwaitDelivery(
            OutgoingSessionMessage(
                from: .user(clientID: clientID), to: address, text: text, sourceSession: source))
    }

    /// Sends a user message from `source` to the idle live session `target`,
    /// lets its turn end, and gives the prompt texts of its transcript.
    ///
    /// - Parameters:
    ///   - source: The source session of the message.
    ///   - target: An idle live session.
    ///   - fixture: The fixture of the test.
    /// - Returns: The prompt texts of `target` after the turn.
    private static func promptTexts(
        afterSendingFrom source: ULID, to target: any RoutedSession, in fixture: Fixture
    ) async throws -> [String] {
        _ = try await send(to: .session(target.id), from: source, in: fixture)
        #expect(await target.awaitIdle())
        return await target.transcript.promptTexts
    }

    // MARK: - Live source

    /// The production change that makes this test fail: a user message with
    /// a source session that gets no header, or that is not delivered at
    /// once to an idle target.
    @Test("a user message from a live source session to an idle session is delivered with the header")
    func anIdleTargetGetsTheHeaderOfALiveSource() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        let target = fixture.makeSession()
        let expected = try await Self.prompt(namingSource: source.id, in: fixture)

        let receipts = try await Self.send(to: .session(target.id), from: source.id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .delivered)])
        #expect(await target.awaitIdle())
        #expect(await target.transcript.promptTexts == [expected])
        await fixture.close([source, target])
    }

    /// The production change that makes this test fail: a delivered message
    /// whose record in the ledger does not name the source session.
    @Test("the delivered record of a user message names its source session")
    func theDeliveredRecordNamesTheSourceSession() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        let target = fixture.makeSession()

        let receipts = try await Self.send(to: .session(target.id), from: source.id, in: fixture)

        let messageID = try #require(receipts.first?.messageID)
        let delivered = try await fixture.directory.message(messageID, to: target.id)
        #expect(delivered?.sourceSession == source.id)
        await fixture.close([source, target])
    }

    /// The production change that makes this test fail: a queued user
    /// message that waits in the queue with no header, or as a body other
    /// than a user message.
    @Test("a user message from a source session to a working session is queued as a user message with the header")
    func aWorkingTargetQueuesTheUserMessageWithTheHeader() async throws {
        let latch = RunLatch()
        let backend = RouterSessionDirectoryDeliveryTests.Backend(script: [Self.firstCall: .hold(latch)])
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend))
        let source = fixture.makeSession()
        let target = try await RouterSessionDirectoryDeliveryTests.startHeldTurn(in: fixture, on: backend)
        let expected = try await Self.prompt(namingSource: source.id, in: fixture)

        let receipts = try await Self.send(to: .session(target.id), from: source.id, in: fixture)
        let waiting = await target.pendingMessages().map(\.body)
        await latch.open()

        let messageID = try #require(receipts.first?.messageID)
        #expect(receipts == [SessionSendReceipt(messageID: messageID, target: target.id, outcome: .queued)])
        #expect(waiting == [.userMessage(prompt: expected, options: UserMessageOptions())])
        #expect(await target.awaitIdle())
        #expect(backend.prompts.last == expected)
        await fixture.close([source, target])
    }

    // MARK: - Recorded source

    /// The production change that makes this test fail: a header that reads
    /// only the live sessions, so a recorded source gets no title.
    @Test("a recorded source session gives its recorded title and folder")
    func aRecordedSourceGivesItsRecordedTitleAndFolder() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = try await fixture.recordClosedSession { $0.title = Self.recordedTitle }
        let target = fixture.makeSession()
        let folder = try #require(try await fixture.directory.summary(of: source)?.workingDirectory)

        let prompts = try await Self.promptTexts(afterSendingFrom: source, to: target, in: fixture)

        #expect(prompts == [Self.prompt(title: Self.recordedTitle, folder: folder)])
        await fixture.close([target])
    }

    /// The production change that makes this test fail: a source session
    /// that the directory does not know, which gets no header.
    @Test("a source session that the directory does not know gives its id")
    func anUnknownSourceGivesItsID() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = ULID()
        let target = fixture.makeSession()

        let prompts = try await Self.promptTexts(afterSendingFrom: source, to: target, in: fixture)

        #expect(prompts == ["From the user, in the session \(source.ulidString)\n\n\(Self.text)"])
        await fixture.close([target])
    }

    // MARK: - Agent start and archived target

    /// The production change that makes this test fail: a first message of
    /// a started session that gets no header.
    @Test("a user message from a source session that starts an agent session has the header")
    func aStartedSessionGetsTheHeader() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        let expected = try await Self.prompt(namingSource: source.id, in: fixture)

        let receipts = try await Self.send(to: .agent(id: Self.agentID, folder: nil), from: source.id, in: fixture)

        let started = try #require(fixture.launcher.sessions.first)
        #expect(receipts.map(\.outcome) == [.started])
        #expect(await started.awaitIdle())
        #expect(await started.transcript.promptTexts == [expected])
        await fixture.close([source])
    }

    /// The production change that makes this test fail: a source session
    /// that lets a user message reach an archived target.
    @Test("a user message from a source session to an archived session is refused as archived")
    func anArchivedTargetIsRefused() async throws {
        let fixture = try await RouterSessionDirectoryDeliveryTests.makeFixture()
        let source = fixture.makeSession()
        let target = try await fixture.recordClosedSession { $0.archivedAt = Date() }

        let receipts = try await Self.send(to: .session(target), from: source.id, in: fixture)

        #expect(
            receipts == [
                SessionSendReceipt(target: target, outcome: .refused, reason: SessionAddressResolution.archivedReason)
            ])
        await fixture.close([source])
    }
}
