import Foundation
import FoundationModelsDecision
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of the decision slot and the recording of a session.
///
/// The `index.md` of a root session records the chosen model of the decision
/// slot. A decision writes nothing to a transcript or to a session record.
///
/// The test profile has a decision candidate that fits after the trio, so the
/// decision model is not the flash model, and the test can tell the two
/// fields apart. The loader gives a stub model that gives log probabilities
/// for the decision candidate, so a decision succeeds. No test downloads or
/// loads a model, and no test makes a network request.
@Suite("The decision slot and the recording of a session")
struct DecisionRecordingTests {
    // MARK: - Fixed values

    /// The prefix of the temp directory of each test.
    private static let tempDirPrefix = "DecisionRecordingTests"

    /// The one decision candidate of ``profile``. It fits after the trio, and
    /// it is not a candidate of another slot.
    private static let deciderRef: ModelRef = "org/decider-fits"

    /// The model reference of the logits-capable container of ``deciderRef``.
    private static let deciderContainerRef: ModelRef = "org/logits-stub"

    /// The context window of the logits-capable container.
    private static let deciderContextWindow = 4096

    /// The start of an assistant message that turns reasoning off: the
    /// thinking block is closed.
    private static let closedThinkingSuffix = "<think>\n\n</think>\n\n"

    /// The start of an assistant message that turns reasoning on.
    private static let openThinkingSuffix = "<think>\n"

    /// The prompt of the root session.
    private static let prompt = "hello"

    /// The state of the decision session.
    private static let state: DecisionState = "The build is red."

    /// The yes-or-no question of the decision.
    private static let question: Question = .binary(instructions: "Does the state report a failure?")

    /// The test profile: the standard test profile, with ``deciderRef`` as
    /// the one decision candidate.
    private static var profile: ProfileDefinition {
        var profile = RouterTestFixtures.profile()
        profile.decision = [deciderRef]
        return profile
    }

    // MARK: - Stubs

    /// A ``ModelLoader`` that gives a logits-capable container for
    /// ``deciderRef``, and what ``StubModelLoader`` gives for each other
    /// model.
    private struct DeciderLoader: ModelLoader {
        /// The loader of each model that is not ``deciderRef``.
        let base = StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension)

        /// The container of ``deciderRef``.
        let decider: any LoadedLLMContainer

        func loadLLM(
            ref: ModelRef, slot: ModelSlot, context: Int, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            guard ref == DecisionRecordingTests.deciderRef else {
                return try await base.loadLLM(ref: ref, slot: slot, context: context, reporting: reporting)
            }
            return decider
        }

        func loadEmbedder(
            ref: ModelRef, slot: ModelSlot, reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            try await base.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    /// The result of one resolve: the router, the profile, and the
    /// directories of the test.
    private struct Fixture {
        /// The router of the resolve. The test keeps it alive.
        let router: Router

        /// The resolved profile.
        let profile: LanguageModelProfile

        /// The cache directory of the router.
        let cacheDir: URL

        /// The durable transcripts root of the router.
        let recordingsDir: URL

        /// Removes the directories of the fixture.
        func removeDirectories() {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
    }

    // MARK: - Helpers

    /// Resolves ``profile`` over a ``DeciderLoader``, with a router that
    /// writes each session to disk.
    ///
    /// - Returns: The fixture. The caller removes its directories.
    /// - Throws: The error of the resolve, after the removal of the
    ///   directories.
    @MainActor
    private static func resolve() async throws -> Fixture {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let logits = StubLogits(reasoningOffSuffix: closedThinkingSuffix, reasoningOnSuffix: openThinkingSuffix)
        let decider = LiveLLMContainer(
            model: LogitsStubLanguageModel(logits: logits), ref: deciderContainerRef,
            contextWindow: deciderContextWindow, tokenCounter: CharacterTokenCounter())
        let router = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: JSONLRecorder(directory: recordingsDir),
            loader: DeciderLoader(decider: decider))
        let profile = try await RouterTestFixtures.removingDirectoryOnThrow(
            cacheDir, alsoOnThrow: { try? FileManager.default.removeItem(at: recordingsDir) }
        ) {
            try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        }
        return Fixture(router: router, profile: profile, cacheDir: cacheDir, recordingsDir: recordingsDir)
    }

    /// The record in the `index.md` of a root session.
    ///
    /// - Parameters:
    ///   - session: The root session.
    ///   - fixture: The fixture that vended the session.
    /// - Returns: The record.
    /// - Throws: The `#require` failure when the session has no `index.md`,
    ///   or what the read throws.
    private static func record(of session: any RoutedSession, in fixture: Fixture) throws -> SessionRecord {
        let directory = RouterTestFixtures.sessionDirectory(
            of: session.id, routerId: fixture.router.id, recordingsDir: fixture.recordingsDir)
        return try #require(try SessionIndexFile.read(in: directory))
    }

    /// The bytes of each file under `directory`, by the path of the file
    /// relative to `directory`.
    ///
    /// - Parameter directory: The directory to read.
    /// - Returns: The bytes of each file.
    /// - Throws: What a read of a file throws.
    private static func fileContents(under directory: URL) throws -> [String: Data] {
        let root = directory.resolvingSymlinksInPath().path(percentEncoded: false)
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        let files = try enumerator.compactMap { item -> (String, Data)? in
            let url = try #require(item as? URL).resolvingSymlinksInPath()
            guard !url.hasDirectoryPath else { return nil }
            return (String(url.path(percentEncoded: false).dropFirst(root.count)), try Data(contentsOf: url))
        }
        return Dictionary(uniqueKeysWithValues: files)
    }

    // MARK: - The resolved profile

    @Test("a root session's index.md records the chosen model of the decision slot")
    @MainActor
    func rootRecordHoldsTheDecisionModel() async throws {
        let fixture = try await Self.resolve()
        defer { fixture.removeDirectories() }
        let root = fixture.profile.standard.makeSession()
        defer { await root.close() }

        let resolved = try #require(try Self.record(of: root, in: fixture).profile)

        #expect(resolved.decision == fixture.profile.decision.chosen)
    }

    @Test("the decision model of a root session's record round-trips through JSON")
    @MainActor
    func decisionModelRoundTripsThroughJSON() async throws {
        let fixture = try await Self.resolve()
        defer { fixture.removeDirectories() }
        let root = fixture.profile.standard.makeSession()
        defer { await root.close() }

        let record = try Self.record(of: root, in: fixture)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONEncoder().encode(record))

        #expect(decoded.profile?.decision == fixture.profile.decision.chosen)
    }

    // MARK: - No transcript

    @Test("a decision changes no file in the recording directory")
    @MainActor
    func decisionChangesNoRecordedFile() async throws {
        let fixture = try await Self.resolve()
        defer { fixture.removeDirectories() }
        let root = fixture.profile.standard.makeSession()
        defer { await root.close() }
        _ = try await root.respond(to: Self.prompt)
        let before = try Self.fileContents(under: fixture.recordingsDir)

        _ = try await fixture.profile.decision.makeSession(state: Self.state).decide([Self.question])

        #expect(try Self.fileContents(under: fixture.recordingsDir) == before)
    }
}
