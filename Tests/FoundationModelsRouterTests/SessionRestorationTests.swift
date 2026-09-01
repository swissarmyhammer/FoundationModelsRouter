import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^w30hzsy: the public single-session restore surface
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:)``.
///
/// The suite proves the three instructions cases the card names. `nil` keeps
/// the recorded string and writes nothing. A supplied string equal to the
/// recorded one writes nothing. A supplied string that differs replaces the
/// recorded one and appends exactly one ``TranscriptEvent/Kind/divergence``
/// event. It also proves the catchable error a missing session raises, and
/// the read-only accessor for a recorded working directory.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a plain stub
/// ``LoadedLLMContainer`` over ``StubSessionBackend``, and a ``JSONLRecorder``
/// writing into a temp directory — so the suite needs no network and no GPU.
/// A "fresh process" is a second ``Router`` built over the same recording
/// root, exactly as the sibling tree-restoration suite builds one.
@Suite("Session restoration: restoreSession(id:)")
struct SessionRestorationTests {
    // MARK: - Stub container

    /// Vends a plain ``StubSessionBackend`` for every session.
    private struct BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: "stub response")
        }
    }

    // MARK: - Fixtures

    /// The instructions the recorded session was vended with.
    ///
    /// It is no substring of the divergence marker's own phrase, so a test
    /// can assert the marker carries no instructions body.
    private static let recordedInstructions = "be terse and cite the file"

    /// The instructions a resuming caller assembles again. It differs from
    /// ``recordedInstructions`` in content and in length.
    private static let freshInstructions = "be verbose, cite the file, and name the module"

    /// The prompt the recorded session answers, so its transcript and its
    /// sidecar are both on disk before a restore reads them.
    private static let recordedPrompt = "remember 42"

    /// One recorded root session, plus everything a restore of it needs kept
    /// alive for the length of a test.
    private struct Recording {
        /// The recorded root session's span id.
        let sessionId: ULID

        /// The working directory the root session was vended with.
        let workingDirectory: URL

        /// The recording root ``TranscriptTree/load(under:)`` reads.
        let routerDirectory: URL

        /// The profile a restore runs against — a second router over the same
        /// recording root, standing in for a fresh process.
        let resumingProfile: LanguageModelProfile

        /// The recording profile, retained so its resident models outlive the
        /// restore.
        let recordingProfile: LanguageModelProfile

        /// The one live writer on the recording root, shared by both routers.
        let recorder: JSONLRecorder
    }

    /// Records one root session and resolves a second router over the same
    /// recording root.
    ///
    /// A recording root admits one live writer, and a restore that appends a
    /// divergence marker writes, so both routers share one recorder.
    ///
    /// - Parameters:
    ///   - cacheDir: The per-test cache directory.
    ///   - recordingsDir: The per-test durable transcripts root.
    ///   - instructions: The instructions the root session is vended with.
    ///   - workingDirectory: A working-directory override, or `nil` for the
    ///     session's own recording directory.
    /// - Returns: The recorded session and the profile to restore it with.
    private static func recordRoot(
        cacheDir: URL,
        recordingsDir: URL,
        instructions: String?,
        workingDirectory: URL? = nil
    ) async throws -> Recording {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let loader = StubModelLoader(
            container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension)

        let recordingRouter = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder, loader: loader)
        let recordingProfile = try await recordingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = recordingProfile.standard.makeSession(
            instructions: instructions, workingDirectory: workingDirectory)
        _ = try await root.respond(to: recordedPrompt)

        let resumingRouter = RouterTestFixtures.makeRouter(
            id: recordingRouter.id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            loader: loader
        )
        let resumingProfile = try await resumingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        return Recording(
            sessionId: root.id,
            workingDirectory: root.workingDirectory,
            routerDirectory: RouterTestFixtures.routerDirectory(
                routerId: recordingRouter.id, recordingsDir: recordingsDir),
            resumingProfile: resumingProfile,
            recordingProfile: recordingProfile,
            recorder: recorder
        )
    }

    /// Every divergence event one session recorded.
    ///
    /// - Parameters:
    ///   - id: The session's span id.
    ///   - routerDirectory: The recording root to read.
    /// - Returns: The session's divergence events, in `seq` order.
    private static func divergenceEvents(
        session id: ULID, under routerDirectory: URL
    ) throws -> [TranscriptEvent] {
        let tree = try TranscriptTree.load(under: routerDirectory)
        return try tree.events(forSession: id).filter { $0.kind == .divergence }
    }

    // MARK: - instructions: nil keeps the recorded string

    @Test("restoreSession with no instructions keeps the recorded instructions")
    @MainActor
    func nilInstructionsKeepsTheRecordedInstructions() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        let restored = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId)

        let session = try #require(restored.session as? RoutedSessionActor)
        #expect(session.instructions == Self.recordedInstructions)
    }

    @Test("restoreSession with no instructions records no divergence event")
    @MainActor
    func nilInstructionsRecordsNoDivergenceEvent() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        _ = try await recording.resumingProfile.standard.restoreSession(id: recording.sessionId)

        let markers = try Self.divergenceEvents(
            session: recording.sessionId, under: recording.routerDirectory)
        #expect(markers.isEmpty)
    }

    // MARK: - Supplied instructions equal to the recorded string

    @Test("instructions equal to the recorded string record no divergence event")
    @MainActor
    func equalInstructionsRecordNoDivergenceEvent() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.recordedInstructions)

        let markers = try Self.divergenceEvents(
            session: recording.sessionId, under: recording.routerDirectory)
        #expect(markers.isEmpty)
    }

    // MARK: - Supplied instructions that differ

    @Test("instructions that differ from the recorded string replace them on the restored session")
    @MainActor
    func differingInstructionsReplaceTheRecordedOnes() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        let restored = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let session = try #require(restored.session as? RoutedSessionActor)
        #expect(session.instructions == Self.freshInstructions)
    }

    @Test("instructions that differ from the recorded string record exactly one divergence event")
    @MainActor
    func differingInstructionsRecordOneDivergenceEvent() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let markers = try Self.divergenceEvents(
            session: recording.sessionId, under: recording.routerDirectory)
        #expect(markers.count == 1)
    }

    @Test("the divergence event names both instruction lengths and carries neither body")
    @MainActor
    func divergenceEventNamesBothLengthsAndNoBody() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let markers = try Self.divergenceEvents(
            session: recording.sessionId, under: recording.routerDirectory)
        let text = try #require(markers.first?.text)
        #expect(text.contains(RestoredSession.instructionsDivergencePhrase))
        #expect(text.contains("recorded \(Self.recordedInstructions.count) characters"))
        #expect(text.contains("supplied \(Self.freshInstructions.count) characters"))
        #expect(!text.contains(Self.recordedInstructions))
        #expect(!text.contains(Self.freshInstructions))
    }

    // MARK: - A missing session is a catchable error

    @Test("restoreSession throws sessionNotFound for an id the recording root does not hold")
    @MainActor
    func restoringAnUnknownSessionThrowsSessionNotFound() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions)
        let unknownId = ULID.generate()

        await #expect(throws: TranscriptTreeError.sessionNotFound(unknownId)) {
            _ = try await recording.resumingProfile.standard.restoreSession(id: unknownId)
        }
    }

    // MARK: - The recorded working directory, read before a restore

    @Test("recordedWorkingDirectory returns the working directory the session was vended with")
    @MainActor
    func recordedWorkingDirectoryReturnsTheVendedOverride() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let overrideDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            try? FileManager.default.removeItem(at: overrideDir)
        }

        let recording = try await Self.recordRoot(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions,
            workingDirectory: overrideDir
        )
        #expect(recording.workingDirectory == overrideDir)

        let read = try recording.resumingProfile.standard.recordedWorkingDirectory(
            ofSession: recording.sessionId)
        #expect(read == overrideDir)
    }
}
