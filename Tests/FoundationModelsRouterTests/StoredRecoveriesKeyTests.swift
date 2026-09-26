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

    /// The recoveries that the fixture's `session.json` stores.
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

    /// The object at `configuration.repetitionDetection` of a `session.json`.
    ///
    /// - Parameter sidecar: The whole JSON object of the file.
    /// - Returns: The repetition detection object, or `nil`.
    private static func storedDetection(in sidecar: [String: Any]) -> [String: Any]? {
        let configuration = sidecar["configuration"] as? [String: Any]
        return configuration?["repetitionDetection"] as? [String: Any]
    }

    /// Reads the JSON object of the `session.json` at `url`.
    ///
    /// - Parameter url: The file.
    /// - Returns: The JSON object.
    /// - Throws: What the read or the parse throws, or a failed requirement.
    private static func readSidecarObject(at url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Copies the fixture into a new recordings root, in the nested layout
    /// `<recordingsDir>/<routerId>/<sessionId>/`, and restores its session
    /// through a router with the fixture's router id.
    ///
    /// - Parameter storedRecoveries: A value to write at the stored key of
    ///   the copy before the restore, or `nil` to keep the bytes of the
    ///   fixture.
    /// - Returns: The restored root session.
    /// - Throws: What the copy, the resolve or the restore throws.
    @MainActor
    private static func restoreFixture(storedRecoveries: Int? = nil) async throws -> RoutedSessionActor {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        let sidecar = try #require(try SessionSidecar.read(in: fixtureSessionDirectory))
        let routerId = try #require(sidecar.routerId)
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: routerId, recordingsDir: recordingsDir)
        try FileManager.default.createDirectory(at: routerDirectory, withIntermediateDirectories: true)
        let sessionDirectory = routerDirectory.appendingPathComponent(fixtureSessionId, isDirectory: true)
        try FileManager.default.copyItem(at: fixtureSessionDirectory, to: sessionDirectory)
        if let storedRecoveries {
            try writeStoredRecoveries(storedRecoveries, in: sessionDirectory)
        }

        let router = RouterTestFixtures.makeRouter(
            id: routerId, cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            loader: StubModelLoader(
                container: ConfiguredLLMContainer(responseText: cannedText),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: fixtureContext), reporting: ResolutionProgress())
        let sessionId = try #require(ULID(ulidString: fixtureSessionId))
        let restored = try await profile.standard.restoreSessionTree(root: sessionId)
        return try #require(restored.root as? RoutedSessionActor)
    }

    /// Writes `recoveries` at the stored key of the `session.json` in
    /// `sessionDirectory`, and changes nothing else of the object.
    ///
    /// - Parameters:
    ///   - recoveries: The value to store.
    ///   - sessionDirectory: The directory of the session.
    /// - Throws: What the read, the parse or the write throws.
    private static func writeStoredRecoveries(_ recoveries: Int, in sessionDirectory: URL) throws {
        let url = sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
        var sidecar = try readSidecarObject(at: url)
        var configuration = try #require(sidecar["configuration"] as? [String: Any])
        var detection = try #require(storedDetection(in: sidecar))
        #expect(detection[storedKey] as? Int == fixtureRecoveries)
        detection[storedKey] = recoveries
        configuration["repetitionDetection"] = detection
        sidecar["configuration"] = configuration
        try FileManager.default.removeItem(at: url)
        try JSONSerialization.data(withJSONObject: sidecar).write(to: url)
    }

    @Test("a recording written before the rename loads, and its recoveriesPerTurn reads back as recoveriesPerAnswer")
    @MainActor
    func recordingWrittenBeforeTheRenameLoads() async throws {
        let restored = try await Self.restoreFixture()

        #expect(restored.repetitionDetection.recoveriesPerAnswer == Self.fixtureRecoveries)
        #expect(await restored.transcript.promptTexts == Self.fixturePrompts)
    }

    @Test("the value at the stored key recoveriesPerTurn is the value the restore reads, not a default")
    @MainActor
    func storedValueIsTheValueTheRestoreReads() async throws {
        let stored = RepetitionDetection.defaultRecoveriesPerAnswer + 1

        let restored = try await Self.restoreFixture(storedRecoveries: stored)

        #expect(restored.repetitionDetection.recoveriesPerAnswer == stored)
    }

    @Test("a session written now still writes the key recoveriesPerTurn in session.json")
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
        _ = try await session.respond(to: Self.newSessionPrompt)

        let url = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
            .appendingPathComponent(session.id.description, isDirectory: true)
            .appendingPathComponent("session.json", isDirectory: false)
        let detection = try #require(Self.storedDetection(in: try Self.readSidecarObject(at: url)))
        #expect(detection[Self.storedKey] as? Int == recoveries)
        #expect(detection[Self.swiftName] == nil)
    }
}
