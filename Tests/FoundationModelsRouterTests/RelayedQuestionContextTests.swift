import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises rule R5 (task ^k8wkxj2): a relayed question is not model input.
///
/// A child session asks a question q, and a ``SubagentQuestionRelay`` sends q
/// up to the relaying session P. The journal of P keeps q, so a restore and
/// a replay of the events still find it. The context of the model of P does
/// not hold q: not live, and not after a restore of P.
///
/// Each test records P to disk and restores it with a second router over the
/// same recording root, as a new process does. The steps have a fixed order,
/// and each wait ends on the question or on the settle of the relaying run.
/// Everything runs against the scripted ``BackgroundingBackend``, so the suite
/// needs no network and no GPU.
@Suite("A relayed question is not model input, also after a restore")
struct RelayedQuestionContextTests {
    // MARK: - Constants

    /// The prefix of each temporary directory of this suite.
    private static let tempDirPrefix = "RelayedQuestionContextTests"

    /// The agent name of the child of the root.
    private static let reviewer = "reviewer"

    // MARK: - Helpers

    /// Makes a root session that records under `recordingsDir`, whose
    /// relaying run starts one child that asks one form question.
    ///
    /// - Parameters:
    ///   - rootStep: The relaying level of the root.
    ///   - recordingsDir: The durable transcripts root.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        rootStep: SubagentRelayStep, recordingsDir: URL
    ) async throws -> SubagentRelayFixture {
        try await SubagentRelayFixture.make(
            root: rootStep, children: [.ask(SubagentAskStep())], recordingsDir: recordingsDir)
    }

    /// Starts the relaying run of the root, and reads the feed of the root
    /// up to the relayed question. The read also ends when a run of the root
    /// settles, so a relay that sends no question fails the test.
    ///
    /// - Parameter fixture: The root session and its box.
    /// - Returns: The relayed question at the root.
    /// - Throws: When the feed of the root holds no question.
    private static func relayedQuestion(of fixture: SubagentRelayFixture) async throws -> OperationEvent {
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        try await fixture.start()
        let outputs = await SessionWorkEventTests.outputs(from: &feed) { event in
            SessionEventCase.elicitationRequested.matches(event) || SessionEventCase.runSettled.matches(event)
        }
        return try firstQuestion(in: outputs)
    }

    /// Whether `transcript` holds the question of `event`: as a run event
    /// with the id of the question, or as text that holds the message of the
    /// question.
    ///
    /// - Parameters:
    ///   - event: The `.elicitation` event of a question.
    ///   - transcript: The context of a model.
    /// - Returns: `true` when the model reads the question.
    /// - Throws: When `event` carries no question.
    private static func holds(_ event: OperationEvent, in transcript: Transcript) throws -> Bool {
        let question = try #require(event.elicitation)
        let entries = Array(transcript)
        let asRunEvent = TranscriptEntrySegments.operationEvents(in: entries).contains {
            $0.elicitation?.elicitationId == question.elicitationId
        }
        let asText = entries.contains { CharacterTokenCounter.content(of: $0).contains(question.message) }
        return asRunEvent || asText
    }

    /// Whether `transcript` holds the terminal of the run `correlationID`.
    ///
    /// - Parameters:
    ///   - correlationID: The token of a run.
    ///   - transcript: The context of a model.
    /// - Returns: `true` when the model reads how the run ended.
    private static func holdsTerminal(ofRun correlationID: String, in transcript: Transcript) -> Bool {
        TranscriptEntrySegments.operationEvents(in: Array(transcript)).contains {
            $0.correlationID == correlationID && $0.kind == .completed
        }
    }

    /// Restores the session tree of the root `rootID` with a second router
    /// over the recording root of `fixture`, runs `body`, and then closes
    /// each restored session. The close comes also when `body` throws.
    ///
    /// - Parameters:
    ///   - rootID: The id of the recorded root session to restore.
    ///   - fixture: The fixture whose router recorded the root.
    ///   - recordingsDir: The durable transcripts root.
    ///   - body: The checks of the test.
    /// - Throws: What the resolve, the restore or `body` throws.
    private static func withRestoredTree(
        root rootID: ULID, of fixture: SubagentRelayFixture, recordingsDir: URL,
        _ body: (RestoredSessionTree) async throws -> Void
    ) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let router = RouterTestFixtures.makeRouter(
            id: fixture.base.router.id, cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: await fixture.base.router.recorder,
            loader: StubModelLoader(container: BackgroundingLLMContainer(), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let tree = try await profile.standard.restoreSessionTree(root: rootID)
        // The router stays alive until each restored session closed.
        defer {
            await SessionFixtureLifecycle.close(tree)
            withExtendedLifetime(router) {}
        }
        try await body(tree)
    }

    // MARK: - Restore

    /// The production change that makes this test fail: a restore context
    /// that keeps the `.toolOutput` journal entry of a relayed question
    /// (`ContextRenderer.context(of:)` with no filter of relayed questions).
    @Test("a restore of the relaying level gives a context with no relayed question, and keeps the other run events")
    func aRestoreOfTheRelayingLevelLeavesTheQuestionOutOfTheContext() async throws {
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: recordingsDir) }
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let fixture = try await Self.makeFixture(rootStep: rootStep, recordingsDir: recordingsDir)
        var asked: OperationEvent?
        try await fixture.base.endingAfter(opening: [rootStep.gate]) {
            let question = try await Self.relayedQuestion(of: fixture)
            asked = question
            // The live path: the journal writes no entry to the backend, and
            // a relayed question makes no run mail.
            #expect(try Self.holds(question, in: await fixture.session.transcript) == false)
        }
        let question = try #require(asked)
        let childID = try #require(fixture.box.children.first).session.id

        try await Self.withRestoredTree(root: fixture.session.id, of: fixture, recordingsDir: recordingsDir) { tree in
            let root = try #require(tree.session(fixture.session.id))
            let rootContext = await root.transcript
            #expect(try Self.holds(question, in: rootContext) == false)
            #expect(Self.holdsTerminal(ofRun: question.correlationID, in: rootContext))
        }
        // The child is a root session of its own. It asked the question
        // itself, so its context keeps it.
        try await Self.withRestoredTree(root: childID, of: fixture, recordingsDir: recordingsDir) { tree in
            let child = try #require(tree.session(childID))
            #expect(try Self.holds(question, in: await child.transcript))
        }
    }

    // MARK: - A recorded fork

    /// The prompt of the second answer of the root. That answer comes after
    /// the journal of the root recorded the question, so a fork cut after it
    /// inherits the question in its recorded prefix.
    private static let promptAfterTheQuestion = "continue after the question"

    /// The production change that makes this test fail: a restore context
    /// of a recorded fork that keeps the journal entry of a relayed
    /// question that the fork inherited from the relaying level.
    @Test("a restored recorded fork of the relaying level gives a context with no relayed question")
    func aRestoredForkOfTheRelayingLevelLeavesTheQuestionOutOfTheContext() async throws {
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: recordingsDir) }
        let rootStep = SubagentRelayStep(agentName: Self.reviewer)
        let fixture = try await Self.makeFixture(rootStep: rootStep, recordingsDir: recordingsDir)
        var asked: OperationEvent?
        try await fixture.base.endingAfter(opening: [rootStep.gate]) {
            asked = try await Self.relayedQuestion(of: fixture)
            _ = try await fixture.session.respond(to: Self.promptAfterTheQuestion)
        }
        let question = try #require(asked)
        let elicitationId = try #require(question.elicitation).elicitationId
        let rootDirectory = fixture.session.recordingDirectory
        let routerDirectory = rootDirectory.deletingLastPathComponent()
        let forkDirectory = try RecordedForkFixtures.writeFork(
            under: rootDirectory,
            cut: try RecordedForkFixtures.cut(atEndOf: fixture.session.id, under: routerDirectory))
        let forkId = try #require(ULID(forkDirectory.lastPathComponent))
        // The recorded prefix of the fork holds the question, so only the
        // context projection can leave it out.
        let inherited = try TranscriptTree.load(under: routerDirectory)
            .effectiveEntryEvents(forSession: forkId).flatMap(\.operationEvents)
        #expect(inherited.contains { $0.elicitation?.elicitationId == elicitationId })

        try await Self.withRestoredTree(root: fixture.session.id, of: fixture, recordingsDir: recordingsDir) { tree in
            let restoredFork = try #require(tree.session(forkId))
            #expect(try Self.holds(question, in: await restoredFork.transcript) == false)
        }
    }
}
