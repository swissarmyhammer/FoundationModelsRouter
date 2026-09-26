import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises a host ``ToolOutputProtection`` rule through a real
/// ``RoutedSession``: the vended session, its fork, and its restore.
///
/// Each session starts with a transcript that holds one protected tool output
/// (a loaded skill body) and one unprotected tool output (a search result),
/// then answers some plain messages. A compaction must keep the skill body word for
/// word next to the summary and remove the search result.
///
/// Everything runs against stubs: a ``StubSessionBackend``-backed container
/// and a ``JSONLRecorder`` in a temp directory. A second router, pointed at the
/// same id and recordings root, restores what the first one recorded.
@Suite("Tool output protection through a session, its fork, and its restore")
struct ToolOutputProtectionSessionTests {
    /// The fixtures every test here reads.
    private typealias Fixtures = ProtectedToolOutputFixtures

    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "ToolOutputProtectionSessionTests"

    // MARK: - Stub container

    /// Vends a ``StubSessionBackend`` per session. A fresh session starts with
    /// ``seedEntries``, as if it already gave the two tool answers. A restored
    /// session starts with the transcript the restore rebuilt.
    private struct SeededLLMContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The canned text every backend this container vends responds with.
        private let responseText = "stub answer"

        /// The entries a fresh session starts with.
        private let seedEntries: [Transcript.Entry]

        /// Creates a container whose fresh sessions start with `seedEntries`.
        ///
        /// - Parameter seedEntries: The entries a fresh session starts with.
        init(seedEntries: [Transcript.Entry]) {
            self.seedEntries = seedEntries
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText, entries: seedEntries)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText, entries: Array(transcript))
        }
    }

    // MARK: - Fixtures

    /// Resolves a profile over a fresh router that records into `directories`.
    ///
    /// - Parameters:
    ///   - directories: The test's temp directories.
    ///   - routerId: The router id, so a second router can restore what the
    ///     first recorded.
    /// - Returns: The resolved profile.
    /// - Throws: What profile resolution throws.
    private static func resolveProfile(in directories: TestDirectories, routerId: ULID) async throws
        -> LanguageModelProfile {
        let container = SeededLLMContainer(
            seedEntries: [TranscriptFixtures.makeInstructions()] + (try Fixtures.skillAnswer())
                + (try Fixtures.searchAnswer()))
        let router = RouterTestFixtures.makeRouter(
            id: routerId,
            cacheDir: directories.cacheDir,
            recordingsDir: directories.recordingsDir,
            recorder: JSONLRecorder(directory: directories.recordingsDir),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        return try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// Compacts `session` against a target one token under its live context,
    /// so the summary gets the room the kept entries leave.
    ///
    /// - Parameter session: The session to compact.
    /// - Returns: What the compaction did.
    /// - Throws: What the compaction throws.
    @discardableResult
    private static func compact(session: RoutedSession) async throws -> CompactionResult {
        try await session.compact(budget: budgetJustUnder(await session.transcript))
    }

    /// Asserts that `transcript` keeps the skill body word for word and holds
    /// the search result nowhere.
    ///
    /// - Parameter transcript: The transcript after the compaction.
    private static func expectProtectedOnly(in transcript: Transcript) {
        let entries = Array(transcript)
        #expect(Fixtures.outputText(in: entries, id: Fixtures.skillCallId) == Fixtures.skillBody)
        #expect(Fixtures.outputText(in: entries, id: Fixtures.searchCallId) != Fixtures.searchOutput)
    }

    // MARK: - The vended session

    @Test("a session vended with the rule keeps the protected output through a compaction and reports its size")
    func vendedSessionKeepsTheProtectedOutputThroughACompaction() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(toolOutputProtection: Fixtures.rule)
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)

        let result = try await Self.compact(session: session)

        #expect(result.summary != nil)
        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(result.protectedTokens == characterCount(of: [try Fixtures.skillCallsEntry(), Fixtures.skillOutputEntry]))
        Self.expectProtectedOnly(in: await session.transcript)
    }

    @Test("a session configured with the rule keeps the protected output through a compaction")
    func configuredSessionKeepsTheProtectedOutputThroughACompaction() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)

        let result = try await Self.compact(session: session)

        #expect(result.stagesApplied == [Summarization.stageName])
        Self.expectProtectedOnly(in: await session.transcript)
    }

    @Test("a session vended with no rule keeps no tool output: the summary replaces the skill output")
    func vendedSessionWithoutARuleKeepsNoToolOutput() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession()
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)

        let result = try await Self.compact(session: session)

        #expect(result.protectedTokens == 0)
        let transcript = await session.transcript
        #expect(Fixtures.outputText(in: Array(transcript), id: Fixtures.skillCallId) == nil)
    }

    // MARK: - The fork

    @Test("a fork inherits the rule and keeps the protected output through its own compaction")
    func forkInheritsTheRule() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)

        let fork = try await session.fork(workingDirectory: nil)
        try await Self.compact(session: fork)

        Self.expectProtectedOnly(in: await fork.transcript)
    }

    // MARK: - The restore

    @Test("a session restored with the rule keeps the protected output through its own compaction")
    func restoredSessionKeepsTheRule() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let routerId = ULID.generate()
        let original = try await Self.resolveProfile(in: directories, routerId: routerId)
        let session = original.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)

        let restoring = try await Self.resolveProfile(in: directories, routerId: routerId)
        let restored = try await restoring.standard.restoreSession(
            id: session.id, recordingRoot: nil, toolOutputProtection: Fixtures.rule
        ).session
        try await Self.compact(session: restored)

        Self.expectProtectedOnly(in: await restored.transcript)
    }

    @Test("the restore of a session compacted with the rule rebuilds the protected output word for word")
    func restoreAfterACompactionKeepsTheProtectedOutput() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let routerId = ULID.generate()
        let original = try await Self.resolveProfile(in: directories, routerId: routerId)
        let session = original.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await driveAnswers(Fixtures.recentAnswerCount, on: session)
        try await Self.compact(session: session)
        let liveTranscript = await session.transcript
        let liveIds = liveTranscript.map(\.id)

        let restoring = try await Self.resolveProfile(in: directories, routerId: routerId)
        let restored = try await restoring.standard.restoreSession(
            id: session.id, toolOutputProtection: Fixtures.rule
        ).session

        let restoredTranscript = await restored.transcript
        #expect(restoredTranscript.map(\.id) == liveIds)
        Self.expectProtectedOnly(in: restoredTranscript)
    }
}
