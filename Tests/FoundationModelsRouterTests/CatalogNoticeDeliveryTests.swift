import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the delivery of a ``CatalogChangeNotice`` to the model: the
/// outbox of each session is a ``CatalogNoticeSink``. A session that mounted
/// a ``CatalogNoticing`` tool joins its board, and each posted notice is one
/// queued ``MailBody/catalogChange(_:)`` mail that the transcript records.
///
/// The notice is no work: it starts no answer and holds no lease. It rides
/// the next submission. Thus a headless run that waits for the no-work idle
/// after its last prompt still gets it, also when a notice comes after that
/// prompt.
///
/// Everything runs against the scripted ``BackgroundingBackend``, so the
/// suite needs no network and no GPU.
@Suite("A catalog notice rides the next submission of each live session")
struct CatalogNoticeDeliveryTests {
    // MARK: - Helpers

    /// A notice of one new agent.
    static let notice = CatalogChangeNotice(
        kind: .agents, added: [CatalogEntry(name: "coder", description: "writes code")], removed: [], changed: [])

    /// Makes a session that mounts a ``NoticingTool`` on `board`.
    ///
    /// - Parameters:
    ///   - board: The board of the tool.
    ///   - parentCall: The parent call of the session, or `nil` for a root.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        board: CatalogNoticeBoard, parentCall: ToolContext? = nil
    ) async throws -> BackgroundingSessionFixture {
        try await BackgroundingSessionFixture.make(
            prefix: "CatalogNoticeDeliveryTests", tools: [NoticingTool(catalogNoticeBoard: board)],
            parentCall: parentCall)
    }

    /// The catalog-change mail of `session`, in queue order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The notice of each queued catalog-change mail.
    private static func queuedNotices(of session: any RoutedSession) async -> [CatalogChangeNotice] {
        await session.pendingMessages().compactMap { mail in
            guard case .catalogChange(let notice) = mail.body else { return nil }
            return notice
        }
    }

    // MARK: - Tests

    @Test("a notice is one queued mail that starts no answer and is no work")
    func aNoticeIsQueuedMailThatIsNoWork() async throws {
        let board = CatalogNoticeBoard()
        let fixture = try await Self.makeFixture(board: board)
        try await fixture.endingAfter {
            #expect(board.sessionIDs == [fixture.session.id])

            await board.post(Self.notice)

            let mail = try #require(await fixture.session.pendingMessages().only)
            #expect(mail.body == .catalogChange(Self.notice))
            #expect(mail.sender == .catalog(.agents))
            #expect(fixture.session.runPlane.workRegistry.hasWork == false)
            #expect(await fixture.session.awaitIdle())
            #expect(fixture.backend.receivedPrompts.isEmpty)
        }
    }

    @Test("the next prompt carries the text of the notice before the text of the user")
    func theNextPromptCarriesTheNotice() async throws {
        let board = CatalogNoticeBoard()
        let fixture = try await Self.makeFixture(board: board)
        try await fixture.endingAfter {
            await board.post(Self.notice)

            _ = try await fixture.session.respond(to: "hello")

            let prompt = try #require(fixture.backend.receivedPrompts.only)
            #expect(prompt == Self.notice.text + ContextRenderer.blockSeparator + "hello")
            #expect(await Self.queuedNotices(of: fixture.session).isEmpty)
        }
    }

    @Test("a notice after the last prompt leaves the session at no work, so a headless run ends")
    func aNoticeAfterTheLastPromptGivesTheNoWorkIdle() async throws {
        let board = CatalogNoticeBoard()
        let fixture = try await Self.makeFixture(board: board)
        try await fixture.endingAfter {
            _ = try await fixture.session.respond(to: "the last prompt")
            #expect(await fixture.session.awaitIdle())

            await board.post(Self.notice)

            #expect(await Self.queuedNotices(of: fixture.session) == [Self.notice])
            #expect(fixture.session.runPlane.workRegistry.hasWork == false)
            #expect(await fixture.session.awaitIdle())
            #expect(fixture.backend.receivedPrompts.count == 1)
        }
    }

    @Test("a root session and its child session each get their own copy of a notice")
    func eachLiveSessionGetsItsOwnCopy() async throws {
        let board = CatalogNoticeBoard()
        let root = try await Self.makeFixture(board: board)
        try await root.endingAfter {
            let parentCall = ToolContext(
                sessionID: root.session.id, runPlane: root.session.runPlane,
                sink: DroppingEventSink(), tool: "agents", op: "start agent",
                completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
            let child = try await Self.makeFixture(board: board, parentCall: parentCall)
            try await child.endingAfter {
                #expect(board.sessionIDs == [root.session.id, child.session.id])

                await board.post(Self.notice)

                #expect(await Self.queuedNotices(of: root.session) == [Self.notice])
                #expect(await Self.queuedNotices(of: child.session) == [Self.notice])
            }
        }
    }
}

/// A tool that lists a catalog and posts its changes through
/// ``catalogNoticeBoard``. The model never calls it: its arguments are not
/// ``BackgroundFixtureArguments``, so the ``BackgroundingBackend`` passes it
/// over.
struct NoticingTool: Tool, CatalogNoticing {
    let name = "noticing_catalog"
    let description = "test-only tool that lists a catalog"
    let catalogNoticeBoard: CatalogNoticeBoard

    @Generable
    struct Arguments {
        let name: String
    }

    func call(arguments: Arguments) async throws -> String {
        "listed"
    }
}

extension Array {
    /// The one element of the array, or `nil` when it has not exactly one.
    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}
