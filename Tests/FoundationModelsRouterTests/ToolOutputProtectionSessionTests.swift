import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises a host ``ToolOutputProtection`` rule through a real
/// ``RoutedSession``: the vended session, its fork, and its restore.
///
/// Each session starts with a transcript that holds one protected tool output
/// (a loaded skill body) and one unprotected tool output (a search result),
/// then takes enough turns that both tool turns are old. A fold through each
/// stage must keep the skill body word for word and remove the search result.
///
/// Everything runs against stubs: a ``StubSessionBackend``-backed container
/// and a ``JSONLRecorder`` in a temp directory. A second router, pointed at the
/// same id and recordings root, restores what the first one recorded.
@Suite("Tool output protection through a session, its fork, and its restore")
struct ToolOutputProtectionSessionTests {
    /// The fixtures every test here reads.
    private typealias Fixtures = ProtectedToolOutputFixtures

    // MARK: - Stub container

    /// Vends a ``StubSessionBackend`` per session. A fresh session starts with
    /// ``seedEntries``, as if it already took the two tool turns. A restored
    /// session starts with the transcript the restore rebuilt.
    private final class SeededLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The canned text every backend this container vends responds with.
        let responseText = "stub answer"

        /// The entries a fresh session starts with.
        let seedEntries: [Transcript.Entry]

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

    /// The temp directories one test owns.
    private struct Directories {
        /// The router's cache directory.
        let cache = RouterTestFixtures.makeTempDir(prefix: "ToolOutputProtectionSessionTests")

        /// The durable recordings root.
        let recordings = RouterTestFixtures.makeTempDir(prefix: "ToolOutputProtectionSessionTests")

        /// Removes both directories.
        func remove() {
            try? FileManager.default.removeItem(at: cache)
            try? FileManager.default.removeItem(at: recordings)
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
    private static func resolveProfile(in directories: Directories, routerId: ULID) async throws
        -> LanguageModelProfile
    {
        let container = SeededLLMContainer(
            seedEntries: [TranscriptFixtures.makeInstructions()] + (try Fixtures.skillTurn())
                + (try Fixtures.searchTurn()))
        let router = RouterTestFixtures.makeRouter(
            id: routerId,
            cacheDir: directories.cache,
            recordingsDir: directories.recordings,
            recorder: JSONLRecorder(directory: directories.recordings),
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        return try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
    }

    /// Drives enough turns on `session` that both seeded tool turns are older
    /// than the recency window.
    ///
    /// - Parameter session: The session to drive.
    /// - Throws: What a turn throws.
    private static func driveRecentTurns(on session: RoutedSession) async throws {
        for index in 0..<Fixtures.recentTurnCount {
            _ = try await session.respond(to: "recent turn \(index)")
        }
    }

    /// A budget whose target sits between what ``TurnTruncation`` leaves of
    /// `transcript`, protected pair included, and its whole size: a
    /// deterministic fold always lands under it.
    ///
    /// - Parameter transcript: The live transcript about to be folded.
    /// - Returns: The budget.
    private static func deterministicBudget(for transcript: Transcript) -> TokenBudget {
        let before = Compactor.estimatedTokenCount(of: transcript)
        let floor = Compactor.estimatedTokenCount(of: TurnTruncation(protection: Fixtures.rule).apply(transcript))
        let target = (floor + before) / foldTargetMidpointDivisor
        return TokenBudget(limit: before, target: Double(target) / Double(before))
    }

    /// A budget whose target no deterministic stage can reach, so the fold
    /// falls through to ``Summarization``.
    ///
    /// - Parameter transcript: The live transcript about to be folded.
    /// - Returns: The budget.
    private static func summarizationBudget(for transcript: Transcript) -> TokenBudget {
        let before = Compactor.estimatedTokenCount(of: transcript)
        return TokenBudget(limit: before, target: Double(Self.unreachableTargetTokens) / Double(before))
    }

    /// A target, in tokens, under the header alone.
    private static let unreachableTargetTokens = 1

    /// Asserts that `transcript` keeps the skill body word for word and holds
    /// the search result nowhere.
    ///
    /// - Parameter transcript: The transcript after the fold.
    private static func expectProtectedOnly(in transcript: Transcript) {
        let entries = Array(transcript)
        #expect(Fixtures.outputText(in: entries, id: Fixtures.skillCallId) == Fixtures.skillBody)
        #expect(Fixtures.outputText(in: entries, id: Fixtures.searchCallId) != Fixtures.searchOutput)
    }

    // MARK: - The vended session

    @Test("a session vended with the rule keeps the protected output through a deterministic fold")
    func vendedSessionKeepsTheProtectedOutputThroughADeterministicFold() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(toolOutputProtection: Fixtures.rule)
        try await Self.driveRecentTurns(on: session)

        let result = try await session.compact(budget: Self.deterministicBudget(for: await session.transcript))

        #expect(result.summary == nil)
        #expect(!result.stagesApplied.isEmpty)
        #expect(result.protectedTokens > 0)
        Self.expectProtectedOnly(in: await session.transcript)
    }

    @Test("a session vended with the rule keeps the protected output through a summarization fold")
    func vendedSessionKeepsTheProtectedOutputThroughASummarizationFold() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await Self.driveRecentTurns(on: session)

        let result = try await session.compact(budget: Self.summarizationBudget(for: await session.transcript))

        #expect(result.stagesApplied.last == Summarization.stageName)
        Self.expectProtectedOnly(in: await session.transcript)
    }

    @Test("a session vended with no rule elides the skill output, the behavior before the rule existed")
    func vendedSessionWithoutARuleElidesTheSkillOutput() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession()
        try await Self.driveRecentTurns(on: session)

        _ = try await session.compact(budget: Self.deterministicBudget(for: await session.transcript))

        let transcript = await session.transcript
        #expect(Fixtures.outputText(in: Array(transcript), id: Fixtures.skillCallId) != Fixtures.skillBody)
    }

    // MARK: - The fork

    @Test("a fork inherits the rule and keeps the protected output through its own fold")
    func forkInheritsTheRule() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let profile = try await Self.resolveProfile(in: directories, routerId: .generate())
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await Self.driveRecentTurns(on: session)

        let fork = try await session.fork(workingDirectory: nil)
        _ = try await fork.compact(budget: Self.deterministicBudget(for: await fork.transcript))

        Self.expectProtectedOnly(in: await fork.transcript)
    }

    // MARK: - The restore

    @Test("a session restored with the rule keeps the protected output through its own fold")
    func restoredSessionKeepsTheRule() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let routerId = ULID.generate()
        let original = try await Self.resolveProfile(in: directories, routerId: routerId)
        let session = original.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await Self.driveRecentTurns(on: session)

        let restoring = try await Self.resolveProfile(in: directories, routerId: routerId)
        let restored = try await restoring.standard.restoreSession(
            id: session.id, recordingRoot: nil, toolOutputProtection: Fixtures.rule
        ).session
        _ = try await restored.compact(budget: Self.deterministicBudget(for: await restored.transcript))

        Self.expectProtectedOnly(in: await restored.transcript)
    }

    @Test("the restore of a session folded with the rule rebuilds the protected output word for word")
    func restoreAfterAFoldKeepsTheProtectedOutput() async throws {
        let directories = Directories()
        defer { directories.remove() }
        let routerId = ULID.generate()
        let original = try await Self.resolveProfile(in: directories, routerId: routerId)
        let session = original.standard.makeSession(
            configuration: SessionConfiguration(toolOutputProtection: Fixtures.rule))
        try await Self.driveRecentTurns(on: session)
        _ = try await session.compact(budget: Self.summarizationBudget(for: await session.transcript))
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
