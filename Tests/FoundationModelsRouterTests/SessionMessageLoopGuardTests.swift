import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The loop guards of ``RouterSessionDirectory/send(_:)`` (ROUTER-5): the chain
/// depth, the sends of one turn, the targets of one tag send and the length of
/// a message, for a session sender and a UI sender alike.
///
/// A session sends from inside its turn through a ``DirectorySendTool`` that
/// a ``ScriptedRoundsModel`` calls in each turn, as the `sessions` tool of
/// Multitool does. Each send is the first tool call of its turn, so the
/// directory reads the turn of the sender where the send runs, and never
/// from the event feed of the sender, which can lag behind.
@Suite("RouterSessionDirectory: the loop guards of a send")
struct SessionMessageLoopGuardTests {
    /// A router whose sessions mount one ``DirectorySendTool`` and run over a
    /// model that calls it in each turn.
    struct Fixture {
        /// The cache and recordings folders of the test.
        let directories: TestDirectories

        /// The router whose sessions the test vends.
        let router: Router

        /// The resolved profile of ``router``.
        let profile: LanguageModelProfile

        /// The tool each session mounts.
        let tool: DirectorySendTool

        /// The directory under test, which ``tool`` sends through.
        let directory: RouterSessionDirectory

        /// Vends a root session of ``router`` that mounts ``tool``, and
        /// registers it in ``directory`` when that is not the router's own.
        ///
        /// - Parameter tags: The tags of the session.
        /// - Returns: The session, live in ``directory``.
        func makeSession(tags: Set<String> = []) -> any RoutedSession {
            let session = profile.standard.makeSession(configuration: SessionConfiguration(tools: [tool], tags: tags))
            if directory !== router.sessionDirectory {
                directory.register(session, kind: .root, parentID: nil)
            }
            return session
        }

        /// Closes `sessions` and removes the folders of the test.
        ///
        /// - Parameter sessions: The sessions the test vended.
        func close(_ sessions: [any RoutedSession]) async {
            for session in sessions {
                await session.close()
            }
            directories.remove()
        }
    }

    // MARK: - Constants

    /// The prompt of the user turn that starts a test.
    private static let userPrompt = "start the work"

    /// The text of each message a session sends.
    private static let text = "please pass this on"

    /// The UI client that sends a UI message.
    private static let clientID = "client-a"

    /// The sessions of the chain test: A, B, C, D and E.
    private static let chainLength = 5

    /// The depth of the message that each hop of the chain test delivers:
    /// A to B, B to C, C to D. The hop D to E is above the limit.
    private static let deliveredChainDepths = [1, 2, 3]

    /// The longest message of the guard table: 16 KB of UTF-8.
    private static let messageLimit = 16 * 1024

    /// A character of two UTF-8 bytes, so a text of it is longer in bytes
    /// than in characters.
    private static let twoByteCharacter = "é"

    /// The UTF-8 bytes of ``twoByteCharacter``.
    private static let twoByteCharacterBytes = 2

    /// The sends of one turn that the per-turn test allows.
    private static let loweredSendsPerTurn = 2

    /// The sends that each turn of the per-turn test makes: one more than
    /// the limit.
    private static let sendsPerTurnAboveTheLimit = loweredSendsPerTurn + 1

    /// The prompts of the two turns of the per-turn test.
    private static let twoTurnPrompts = ["the first turn", "the second turn"]

    /// The sessions with the tag of the tag test: two more than the limit of
    /// eight targets.
    private static let taggedSessions = 10

    /// The tag of the tag test.
    private static let tag = "triage"

    /// The targets of a tag send that get the message.
    private static let tagTargetLimit = 8

    // MARK: - Helpers

    /// Makes a fixture whose model calls the tool `callsPerTurn` times in the
    /// one round of each turn.
    ///
    /// - Parameters:
    ///   - callsPerTurn: The tool calls of each turn.
    ///   - directory: Makes the directory under test from the router; the
    ///     router's own directory by default.
    /// - Returns: The fixture.
    static func makeFixture(
        callsPerTurn: Int = 1,
        directory: (Router) -> RouterSessionDirectory = \.sessionDirectory
    ) async throws -> Fixture {
        // Each call of a round has its own text, so no two calls in a row are
        // identical tool calls.
        let calls = (0..<callsPerTurn).map { position in
            ScriptedRoundCall(name: DirectorySendTool.toolName, arguments: #"{"value":"\#(text) \#(position)"}"#)
        }
        let model = ScriptedRoundsModel(log: RenderProbeLog(), rounds: [calls], replaysEachTurn: true)
        let directories = TestDirectories(prefix: "SessionMessageLoopGuardTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: LiveBackendContainer(model: model), cacheDir: directories.cacheDir,
            recordingsDir: directories.recordingsDir)
        let directoryUnderTest = directory(router)
        return Fixture(
            directories: directories, router: router, profile: profile,
            tool: DirectorySendTool(directory: directoryUnderTest), directory: directoryUnderTest)
    }

    /// The chain depth of each message in the ledger of the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - fixture: The fixture of the test.
    /// - Returns: The depths, the oldest message first.
    private static func chainDepths(of id: ULID, in fixture: Fixture) async throws -> [Int] {
        try await fixture.directory.inbox(of: id, markRead: false).map(\.chainDepth)
    }

    // MARK: - Chain depth

    /// The production change that makes this test fail: a depth that does
    /// not grow from turn to turn, or a depth read from the event feed of
    /// the sender, which has not seen the turn when its first tool call
    /// sends.
    @Test("a chain of sends from turn to turn is refused above depth 3, also from the first tool call of a turn")
    func aSendAboveTheChainDepthIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        let sessions = (0..<Self.chainLength).map { _ in fixture.makeSession() }
        for (sender, target) in zip(sessions, sessions.dropFirst()) {
            fixture.tool.route(from: sender.id, to: .session(target.id))
        }

        _ = try sessions[0].send(Self.userPrompt)
        for session in sessions.dropLast() {
            #expect(await session.awaitIdle())
        }

        var depths: [[Int]] = []
        for session in sessions.dropFirst() {
            depths.append(try await Self.chainDepths(of: session.id, in: fixture))
        }
        #expect(depths == Self.deliveredChainDepths.map { [$0] } + [[]])
        for sender in sessions.prefix(Self.deliveredChainDepths.count) {
            #expect(fixture.tool.receipts(of: sender.id).flatMap { $0.map(\.outcome) } == [.delivered])
        }
        let last = try #require(sessions.dropLast().last)
        #expect(
            fixture.tool.receipts(of: last.id)
                == [[SessionSendReceipt(outcome: .refused, reason: SessionMessageLimits().chainTooDeepReason)]])
        await fixture.close(sessions)
    }

    // MARK: - Length

    /// The production change that makes this test fail: a length check that
    /// counts characters instead of UTF-8 bytes, a check that skips one kind
    /// of sender, or a check that runs after the delivery.
    @Test("a text over 16 KB of UTF-8 throws messageTooLong before any delivery, for a UI sender and a session sender")
    func aTextOverTheLengthLimitThrows() async throws {
        let fixture = try await Self.makeFixture()
        let sender = fixture.makeSession()
        let target = fixture.makeSession()
        let overLimit = String(
            repeating: Self.twoByteCharacter, count: Self.messageLimit / Self.twoByteCharacterBytes + 1)
        let senders: [SessionMessageSender] = [.user(clientID: Self.clientID), .session(sender.id)]

        for from in senders {
            await #expect(throws: SessionDirectoryError.messageTooLong(limit: Self.messageLimit)) {
                try await fixture.directory.send(
                    OutgoingSessionMessage(from: from, to: .session(target.id), text: overLimit))
            }
        }

        #expect(try await Self.chainDepths(of: target.id, in: fixture).isEmpty)
        await fixture.close([sender, target])
    }

    /// The production change that makes this test fail: a limit that
    /// refuses a text of exactly 16 KB.
    @Test("a text of exactly 16 KB of UTF-8 is delivered")
    func aTextAtTheLengthLimitIsDelivered() async throws {
        let fixture = try await Self.makeFixture()
        let target = fixture.makeSession()
        let atLimit = String(repeating: Self.twoByteCharacter, count: Self.messageLimit / Self.twoByteCharacterBytes)

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .session(target.id), text: atLimit))

        #expect(receipts.map(\.outcome) == [.delivered])
        await fixture.close([target])
    }

    // MARK: - Sends of one turn

    /// The production change that makes this test fail: no count of the
    /// sends of a turn, or a count that a new turn of the session does not
    /// start again.
    @Test("with a limit of 2 sends a turn, the third send of a turn is refused, and the next turn sends again")
    func theSendAfterTheLimitOfATurnIsRefused() async throws {
        let limits = SessionMessageLimits(maxSendsPerTurn: Self.loweredSendsPerTurn)
        let fixture = try await Self.makeFixture(callsPerTurn: Self.sendsPerTurnAboveTheLimit) { _ in
            RouterSessionDirectory(limits: limits)
        }
        let sender = fixture.makeSession()
        let target = fixture.makeSession()
        fixture.tool.route(from: sender.id, to: .session(target.id))

        for prompt in Self.twoTurnPrompts {
            _ = try sender.send(prompt)
            #expect(await sender.awaitIdle())
        }

        let receipts = fixture.tool.receipts(of: sender.id).flatMap { $0 }
        let refusal = SessionSendReceipt(outcome: .refused, reason: limits.tooManySendsReason)
        let turns = [receipts.prefix(Self.sendsPerTurnAboveTheLimit), receipts.dropFirst(Self.sendsPerTurnAboveTheLimit)]
        for turn in turns {
            #expect(turn.filter { $0 == refusal }.count == 1)
            #expect(turn.filter { $0.outcome != .refused }.count == Self.loweredSendsPerTurn)
        }
        await fixture.close([sender, target])
    }

    // MARK: - Targets of one tag send

    /// The production change that makes this test fail: a tag send that
    /// delivers to each target with no limit.
    @Test("a tag send from a session to 10 sessions delivers to 8 and refuses 2")
    func aTagSendFromASessionRefusesTheTargetsAboveTheLimit() async throws {
        let fixture = try await Self.makeFixture()
        let tagged = (0..<Self.taggedSessions).map { _ in fixture.makeSession(tags: [Self.tag]) }
        let sender = fixture.makeSession()
        fixture.tool.route(from: sender.id, to: .tag(Self.tag))

        _ = try sender.send(Self.userPrompt)
        #expect(await sender.awaitIdle())

        Self.expectTagCap(on: fixture.tool.receipts(of: sender.id).flatMap { $0 }, for: tagged)
        await fixture.close(tagged + [sender])
    }

    /// The production change that makes this test fail: a tag cap that
    /// applies to a session sender only, or a UI message with a depth other
    /// than 1.
    @Test("a tag send from a UI to 10 sessions delivers to 8 and refuses 2, and each UI message has depth 1")
    func aTagSendFromAUIRefusesTheTargetsAboveTheLimit() async throws {
        let fixture = try await Self.makeFixture()
        let tagged = (0..<Self.taggedSessions).map { _ in fixture.makeSession(tags: [Self.tag]) }

        let receipts = try await fixture.directory.send(
            OutgoingSessionMessage(from: .user(clientID: Self.clientID), to: .tag(Self.tag), text: Self.text))

        Self.expectTagCap(on: receipts, for: tagged)
        for target in receipts.prefix(Self.tagTargetLimit) {
            #expect(try await Self.chainDepths(of: try #require(target.target), in: fixture) == [1])
        }
        await fixture.close(tagged)
    }

    /// Expects the receipts of a tag send to `tagged`: the first eight
    /// targets in id order get the message, and each other target is
    /// refused with the reason of the limit.
    ///
    /// - Parameters:
    ///   - receipts: The receipts of the tag send.
    ///   - tagged: The sessions with the tag.
    private static func expectTagCap(on receipts: [SessionSendReceipt], for tagged: [any RoutedSession]) {
        let ids = tagged.map(\.id).sorted()
        let delivered = receipts.prefix(tagTargetLimit)
        #expect(delivered.map(\.target) == ids.prefix(tagTargetLimit).map(Optional.some))
        #expect(delivered.allSatisfy { $0.outcome != .refused })
        #expect(
            Array(receipts.dropFirst(tagTargetLimit))
                == ids.dropFirst(tagTargetLimit).map {
                    SessionSendReceipt(target: $0, outcome: .refused, reason: SessionMessageLimits().tooManyTargetsReason)
                })
    }
}
