import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^5d0qx1b: the Swift property ``RepetitionDetection/recoveriesPerAnswer``
/// keeps the key `recoveriesPerTurn` on disk (`generation-queue.md`, section
/// 5.6). A recording written before the rename loads, and a session written
/// now writes the same key.
///
/// The fixture `Fixtures/PreRequestRenameRecording` is a recording that the
/// router wrote before the work-queue change. The test target excludes
/// `Fixtures`, so each test reads it from disk at a path relative to this
/// file, and copies it into a temporary recordings root before it restores.
@Suite("The stored key recoveriesPerTurn stays on disk")
struct StoredRecoveriesKeyTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "StoredRecoveriesKeyTests"

    /// The stored key of the recoveries of an answer.
    private static let storedKey = "recoveriesPerTurn"

    /// The name of the Swift property, which the file must not hold.
    private static let swiftName = "recoveriesPerAnswer"

    /// The id of the one session of the fixture: the name of its directory.
    private static let fixtureSessionId = "01M3CWVB5NFSC7HFT40W63E4TX"

    /// The recoveries that the fixture's `index.md` stores.
    private static let fixtureRecoveries = 2

    /// The prompts of the two answers that the fixture recorded.
    private static let fixturePrompts = ["first", "second"]

    /// The prompt of the one answer of a session written now.
    private static let newSessionPrompt = "hello"

    /// The text every backend of the restoring router answers with. It is
    /// the text the fixture recorded.
    private static let cannedText = "canned response"

    /// The working context the fixture was recorded with.
    private static let fixtureContext = 1_000

    /// The directory of the fixture's one session, beside this file.
    private static let fixtureSessionDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PreRequestRenameRecording", isDirectory: true)
        .appendingPathComponent(fixtureSessionId, isDirectory: true)

    /// The YAML line of the frontmatter that stores `recoveries` at the
    /// stored key.
    ///
    /// - Parameter recoveries: The stored value.
    /// - Returns: The text of the line, without its indent.
    private static func storedLine(_ recoveries: Int) -> String {
        "\(storedKey): \(recoveries)"
    }

    /// Reads the text of the `index.md` in `sessionDirectory`.
    ///
    /// - Parameter sessionDirectory: The directory of the session.
    /// - Returns: The whole text of the file.
    /// - Throws: What the read throws.
    private static func indexText(in sessionDirectory: URL) throws -> String {
        try String(
            contentsOf: RouterTestFixtures.indexURL(inSessionDirectory: sessionDirectory), encoding: .utf8)
    }

    /// Copies the fixture into a new recordings root, in the nested layout
    /// `<recordingsDir>/<routerId>/<sessionId>/`, and restores its session
    /// through a router with the fixture's router id.
    ///
    /// - Parameter storedRecoveries: A value to write at the stored key of
    ///   the copy before the restore, or `nil` to keep the bytes of the
    ///   fixture.
    /// - Returns: The restored root session. The caller closes it. When the
    ///   root is no ``RoutedSessionActor``, the root closes before the throw.
    /// - Throws: What the copy, the resolve or the restore throws.
    @MainActor
    private static func restoreFixture(storedRecoveries: Int? = nil) async throws -> RoutedSessionActor {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let record = try #require(try SessionIndexFile.read(in: fixtureSessionDirectory))
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: record.routerId, recordingsDir: recordingsDir)
        try FileManager.default.createDirectory(at: routerDirectory, withIntermediateDirectories: true)
        let sessionDirectory = routerDirectory.appendingPathComponent(fixtureSessionId, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureSessionDirectory, to: sessionDirectory)
        if let storedRecoveries {
            try writeStoredRecoveries(storedRecoveries, in: sessionDirectory)
        }

        let router = RouterTestFixtures.makeRouter(
            id: record.routerId, cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(
                container: ConfiguredLLMContainer(responseText: cannedText),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: fixtureContext), reporting: ResolutionProgress())
        let sessionId = try #require(ULID(ulidString: fixtureSessionId))
        let root = try await profile.standard.restoreSessionTree(root: sessionId).root
        return try await RouterTestFixtures.removingDirectoryOnThrow(cacheDir, alsoOnThrow: { await root.close() }) {
            try #require(root as? RoutedSessionActor)
        }
    }

    /// Writes `recoveries` at the stored key of the `index.md` in
    /// `sessionDirectory`, and changes nothing else of the file: the test
    /// edits the YAML line itself, so the restore reads the stored key and
    /// not a value the typed record wrote back.
    ///
    /// - Parameters:
    ///   - recoveries: The value to store.
    ///   - sessionDirectory: The directory of the session.
    /// - Throws: What the read or the write throws, or a failed requirement
    ///   when the file holds no line with the fixture's stored value.
    private static func writeStoredRecoveries(_ recoveries: Int, in sessionDirectory: URL) throws {
        let text = try indexText(in: sessionDirectory)
        let fixtureLine = storedLine(fixtureRecoveries)
        try #require(text.contains(fixtureLine))
        try text.replacingOccurrences(of: fixtureLine, with: storedLine(recoveries))
            .write(
                to: RouterTestFixtures.indexURL(inSessionDirectory: sessionDirectory),
                atomically: true, encoding: .utf8)
    }

    /// The fixture's stored `recoveriesPerTurn` restores as the session's
    /// `recoveriesPerAnswer`, and the fixture's answers come back.
    @Test("a recording written before the rename loads, and its recoveriesPerTurn reads back as recoveriesPerAnswer")
    @MainActor
    func recordingWrittenBeforeTheRenameLoads() async throws {
        let restored = try await Self.restoreFixture()
        defer { await restored.close() }

        #expect(restored.repetitionDetection.recoveriesPerAnswer == Self.fixtureRecoveries)
        #expect(await restored.transcript.promptTexts == Self.fixturePrompts)
    }

    /// A value written at the stored key is the value the restore reads,
    /// not the default.
    @Test("the value at the stored key recoveriesPerTurn is the value the restore reads, not a default")
    @MainActor
    func storedValueIsTheValueTheRestoreReads() async throws {
        let stored = RepetitionDetection.defaultRecoveriesPerAnswer + 1

        let restored = try await Self.restoreFixture(storedRecoveries: stored)
        defer { await restored.close() }

        #expect(restored.repetitionDetection.recoveriesPerAnswer == stored)
    }

    /// A session vended now writes its recoveries under the stored key
    /// `recoveriesPerTurn` in its `index.md`, never under the Swift name.
    @Test("a session written now still writes the key recoveriesPerTurn in index.md")
    @MainActor
    func sessionWrittenNowWritesTheStoredKey() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(
                container: ConfiguredLLMContainer(responseText: Self.cannedText),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let recoveries = RepetitionDetection.defaultRecoveriesPerAnswer + 1
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(repetitionDetection: RepetitionDetection(recoveriesPerAnswer: recoveries)))
        defer { await session.close() }
        _ = try await session.respond(to: Self.newSessionPrompt)

        let sessionDirectory = RouterTestFixtures.sessionDirectory(
            of: session.id, routerId: router.id, recordingsDir: recordingsDir)
        let record = try #require(try SessionIndexFile.read(in: sessionDirectory))
        #expect(record.configuration?.repetitionDetection?.recoveriesPerAnswer == recoveries)
        let text = try Self.indexText(in: sessionDirectory)
        #expect(text.contains(Self.storedLine(recoveries)))
        #expect(!text.contains(Self.swiftName))
    }
}
