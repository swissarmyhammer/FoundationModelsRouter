import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the `index.md` of each session folder: every session that
/// records durably keeps one ``SessionRecord`` as the frontmatter of the
/// `index.md` in its own folder, written before its first transcript event.
/// The record holds the `slot`, the `model`, the resolved `context`, the
/// `instructions`, the `grammar`, the `recordingLevel`, the working folder,
/// the agent spawn and the resolved profile of a root.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container backed by ``StubSessionBackend``, and a ``JSONLRecorder`` writing
/// into a temp directory — so the suite needs no network and no GPU. The
/// format of the file itself is covered by `SessionIndexFileTests`.
@Suite("Session index: one index.md per session folder")
struct SessionIndexTests {
    // MARK: - Fixtures

    /// The answer text of every stub session.
    private static let cannedText = "canned response"

    /// The profile every router of the suite resolves.
    private static let profile = RouterTestFixtures.profile()

    /// The prefix of each temporary directory of the suite.
    private static let tempPrefix = "SessionIndexTests"

    /// The entry count and history ordinal of a new session, whose
    /// transcript holds no entry yet.
    private static let emptyTranscriptEntryCount = 0

    /// The tool-call id of the agent spawn of the on-disk spawn test.
    private static let firstSpawnToolCallId = "agents-tool-call-1"

    /// The tool-call id of the agent spawn of the `.session` event test.
    private static let secondSpawnToolCallId = "agents-tool-call-2"

    /// A router over the stubs, the profile it resolved, and its durable
    /// recordings root.
    private struct Fixture {
        /// The router under test.
        let router: Router
        /// The profile the router resolved.
        let profile: LanguageModelProfile
        /// The durable recordings root of the router.
        let recordingsDir: URL

        /// The folder of a session under the recording root of ``router``.
        ///
        /// - Parameter sessionPath: The ids from the root session to the
        ///   session, in order. A root session is a path of one id.
        /// - Returns: The session folder.
        func directory(of sessionPath: ULID...) -> URL {
            sessionPath.reduce(routerDirectory) { directory, id in
                directory.appendingPathComponent(id.description, isDirectory: true)
            }
        }

        /// The recording root of ``router`` under ``recordingsDir``.
        var routerDirectory: URL {
            RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
        }
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a
    /// durable recordings root, so vended sessions nest their transcripts and
    /// their `index.md` under it.
    ///
    /// - Parameters:
    ///   - recorder: The transcript recorder.
    ///   - cacheDir: The cache directory of the router.
    ///   - recordingsDir: The durable recordings root.
    ///   - recordingLevel: How much the router records. The default is
    ///     ``RecordingLevel/full``.
    /// - Returns: The router.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        recordingLevel: RecordingLevel = .full
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            recordingLevel: recordingLevel,
            probe: RouterTestFixtures.stubProbe,
            metadataSource: StubMetadataSource(raw: RouterTestFixtures.rawMetadata),
            loader: StubModelLoader(
                container: BasicLLMContainer(responseText: cannedText),
                dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool()
        )
    }

    /// Resolves ``profile`` over a router built by
    /// ``makeRouter(recorder:cacheDir:recordingsDir:recordingLevel:)`` in new
    /// temporary directories, runs `body`, and removes the directories.
    ///
    /// - Parameters:
    ///   - recordingLevel: How much the router records. The default is
    ///     ``RecordingLevel/full``.
    ///   - recorder: Makes the recorder of the router from its recordings
    ///     root. The default records each session to disk.
    ///   - body: The test body.
    @MainActor
    private static func withRouter(
        recordingLevel: RecordingLevel = .full,
        recorder: (URL) -> any TranscriptRecorder = { JSONLRecorder(directory: $0) },
        _ body: (Fixture) async throws -> Void
    ) async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = makeRouter(
            recorder: recorder(recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recordingLevel: recordingLevel
        )
        let resolved = try await router.resolve(profile: profile, reporting: ResolutionProgress())
        try await body(Fixture(router: router, profile: resolved, recordingsDir: recordingsDir))
    }

    /// The names of everything directly inside `directory`, one level deep.
    ///
    /// - Parameter directory: The folder to list.
    /// - Returns: The names.
    /// - Throws: The error of the listing.
    private static func fileNames(directlyIn directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    // MARK: - A root writes one index.md

    /// A root writes one `index.md` in its own folder: it has no cut, and the
    /// slot, model, context and recording level are the ones of the vending
    /// handle.
    @Test("a root session writes one index.md into its own folder")
    @MainActor
    func rootWritesOneIndex() async throws {
        try await Self.withRouter { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }

            let rootRecord = try #require(try SessionIndexFile.read(in: fixture.directory(of: root.id)))
            #expect(rootRecord.forkedAtEntryCount == nil)
            #expect(rootRecord.slot == .standard)
            #expect(rootRecord.model == fixture.profile.standard.chosen)
            #expect(rootRecord.context == fixture.profile.standard.resolution.contextTokens)
            #expect(rootRecord.recordingLevel == .full)
        }
    }

    /// A run's whole recording tree holds only one folder per session, and
    /// each session folder holds only its `index.md` and its
    /// `transcript.jsonl`.
    @Test("a run's whole recording tree holds only index.md and transcript.jsonl")
    @MainActor
    func aRunWritesOnlyIndexesAndTranscripts() async throws {
        try await Self.withRouter { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }
            _ = try await root.respond(to: "hello")

            #expect(try Self.fileNames(directlyIn: fixture.routerDirectory) == [root.id.description])
            #expect(
                try Self.fileNames(directlyIn: fixture.directory(of: root.id)) == [
                    SessionIndexFile.fileName, transcriptFileName,
                ])
        }
    }

    // MARK: - Ordering: the index.md precedes any transcript event

    /// The `index.md` of a session is on disk when the first event of its
    /// transcript is appended.
    @Test("a session's index.md exists before its transcript's first event is recorded")
    @MainActor
    func theIndexExistsBeforeTheFirstTranscriptEvent() async throws {
        var observing: ObservingRecorder?
        try await Self.withRouter(recorder: { recordingsDir in
            let recorder = ObservingRecorder(wrapping: JSONLRecorder(directory: recordingsDir))
            observing = recorder
            return recorder
        }) { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }
            _ = try await root.respond(to: "hello")

            let observed = try #require(observing)
            let indexPresence = await observed.indexPresentAtFirstAppend
            #expect(indexPresence == [true])
        }
    }

    /// Wraps a recorder, noting for each session folder whether the
    /// `index.md` of that session was already on disk when its first event
    /// was appended.
    private actor ObservingRecorder: TranscriptRecorder {
        /// The recorder every event goes on to.
        private let wrapped: any TranscriptRecorder
        /// The session folders that have had an event.
        private var seenDirectories: Set<URL> = []
        /// One entry per distinct session folder, in first-append order.
        private(set) var indexPresentAtFirstAppend: [Bool] = []

        /// Wraps `wrapped`.
        ///
        /// - Parameter wrapped: The recorder every event goes on to.
        init(wrapping wrapped: any TranscriptRecorder) {
            self.wrapped = wrapped
        }

        /// Notes whether the `index.md` of `directory` is on disk at its
        /// first event, then appends the event to the wrapped recorder.
        ///
        /// - Parameters:
        ///   - partial: The event.
        ///   - directory: The session folder, or `nil`.
        func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
            if let directory, seenDirectories.insert(directory).inserted {
                indexPresentAtFirstAppend.append(
                    FileManager.default.fileExists(atPath: SessionIndexFile.url(in: directory).path))
            }
            await wrapped.append(partial, to: directory)
        }
    }

    // MARK: - Construction writes nothing; the first index is written after

    /// A session actor built with its initializer, not through
    /// `makeRoutedSessionActor`, writes no `index.md`: construction writes
    /// nothing. ``RoutedSessionActor/writeFirstIndex()`` then writes the
    /// record of the new root: its instructions, slot and model, no cut, and
    /// the resolved profile of the run.
    @Test("a session actor built directly writes no index.md until writeFirstIndex writes it")
    @MainActor
    func aDirectlyBuiltSessionActorWritesNoIndexUntilWriteFirstIndex() async throws {
        try await Self.withRouter { fixture in
            let standard = fixture.profile.standard
            let instructions = "You are a terse assistant."
            let sessionId = ULID.generate()
            let recordingDirectory = standard.recordingDirectory(forSessionId: sessionId)

            let session = RoutedSessionActor(
                profile: fixture.profile,
                routerId: standard.routerId,
                id: sessionId,
                parentId: nil,
                recordingDirectory: recordingDirectory,
                workingDirectory: recordingDirectory,
                backend: standard.container.makeSession(instructions: instructions),
                slot: .standard,
                model: standard.chosen,
                recorder: standard.recorder,
                instructions: instructions,
                grammar: nil,
                persistedEntryCount: Self.emptyTranscriptEntryCount,
                historyOrdinal: Self.emptyTranscriptEntryCount,
                indexWriter: standard.durableRecording?.indexWriter,
                contextTokens: standard.contextTokens,
                tokenCounter: CharacterTokenCounter(),
                tracer: standard.tracer,
                record: .new(SessionFacts())
            )
            defer { await session.close() }
            #expect(session.recordingDirectory == recordingDirectory)
            #expect(session.persistsIndex)
            #expect(!FileManager.default.fileExists(atPath: SessionIndexFile.url(in: recordingDirectory).path))

            session.writeFirstIndex()

            let record = try #require(try SessionIndexFile.read(in: recordingDirectory))
            #expect(record == session.record)
            #expect(record.instructions == instructions)
            #expect(record.slot == .standard)
            #expect(record.model == standard.chosen)
            #expect(record.forkedAtEntryCount == nil)
            #expect(record.forkParentId == nil)
            #expect(record.profile?.definitionName == Self.profile.name)
        }
    }

    // MARK: - Grammar and instructions

    /// A guided session records its grammar source and its instructions.
    @Test("a guided session's index.md carries its grammar source and instructions")
    @MainActor
    func guidedSessionRecordsGrammarAndInstructions() async throws {
        try await Self.withRouter { fixture in
            let grammarSource = #"{"type":"object"}"#
            let instructions = "You are a terse assistant."
            let root = fixture.profile.standard.makeGuidedSession(
                grammar: .jsonSchema(grammarSource), instructions: instructions)
            defer { await root.close() }

            let rootRecord = try #require(try SessionIndexFile.read(in: fixture.directory(of: root.id)))

            #expect(rootRecord.grammar == grammarSource)
            #expect(rootRecord.instructions == instructions)
        }
    }

    // MARK: - The resolved profile

    /// A root records the resolved profile of the run.
    @Test("a root session's index.md carries the resolved profile")
    @MainActor
    func rootIndexCarriesResolvedProfile() async throws {
        try await Self.withRouter { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }

            let resolved = try #require(try SessionIndexFile.read(in: fixture.directory(of: root.id))?.profile)
            #expect(resolved.definitionName == Self.profile.name)
            #expect(resolved.standard == fixture.profile.standard.chosen)
            #expect(resolved.flash == fixture.profile.flash.chosen)
            #expect(resolved.embedding == fixture.profile.embedding.chosen)
            #expect(resolved.context == fixture.profile.standard.resolution.contextTokens)
        }
    }

    // MARK: - Working folder

    /// A root records its default working folder, its own session folder.
    @Test("a root's index.md records its default working directory")
    @MainActor
    func indexRecordsTheRootsOwnWorkingDirectory() async throws {
        try await Self.withRouter { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }
            let rootDir = fixture.directory(of: root.id)
            #expect(root.workingDirectory == rootDir)
            let index = try SessionIndexFile.read(in: rootDir)
            #expect(index?.workingDirectory == rootDir)
        }
    }

    // MARK: - Agent spawn

    /// A root vended with an agent spawn records it in its `index.md`.
    @Test("a session vended with an agentSpawn records it on its root index.md")
    @MainActor
    func sessionVendedWithAgentSpawnRecordsItOnRoot() async throws {
        try await Self.withRouter { fixture in
            let spawningSessionId = ULID.generate()
            let spawn = SessionRecord.AgentSpawn(
                parentSessionId: spawningSessionId, parentToolCallId: Self.firstSpawnToolCallId)
            let root = fixture.profile.standard.makeSession(agentSpawn: spawn)
            defer { await root.close() }

            let rootSpawn = try #require(try SessionIndexFile.read(in: fixture.directory(of: root.id))?.agentSpawn)
            #expect(rootSpawn.parentSessionId == spawningSessionId)
            #expect(rootSpawn.parentToolCallId == Self.firstSpawnToolCallId)
        }
    }

    /// A root vended with an agent spawn stamps it on its recorded `.session`
    /// event and keeps it in its `index.md`.
    @Test("a session vended with an agentSpawn stamps it on its .session event and keeps it in index.md")
    @MainActor
    func sessionVendedWithAgentSpawnStampsItOnTheSessionEvent() async throws {
        let recorder = InMemoryRecorder()
        try await Self.withRouter(recorder: { _ in recorder }) { fixture in
            let spawn = SessionRecord.AgentSpawn(
                parentSessionId: ULID.generate(), parentToolCallId: Self.secondSpawnToolCallId)
            let root = fixture.profile.standard.makeSession(agentSpawn: spawn)
            defer { await root.close() }
            _ = try await root.respond(to: "hello")

            let events = await recorder.events
            let rootFirst = try #require(events.first)
            #expect(rootFirst.sessionId == root.id)
            #expect(rootFirst.kind == .session)
            #expect(rootFirst.agentSpawn == spawn)

            #expect(try SessionIndexFile.read(in: fixture.directory(of: root.id))?.agentSpawn == spawn)
        }
    }

    /// A root vended with no agent spawn stamps none on its `.session` event.
    @Test("a root session vended without an agentSpawn stamps nil on its recorded .session event")
    @MainActor
    func rootSessionWithoutAgentSpawnStampsNilOnTheSessionEvent() async throws {
        let recorder = InMemoryRecorder()
        try await Self.withRouter(recorder: { _ in recorder }) { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }
            _ = try await root.respond(to: "hello")

            let events = await recorder.events
            let first = try #require(events.first)
            #expect(first.sessionId == root.id)
            #expect(first.kind == .session)
            #expect(first.agentSpawn == nil)
        }
    }

    // MARK: - Recording levels

    /// At ``RecordingLevel/off`` nothing durable is recorded: no `index.md`
    /// and no transcript, so the recording root of the router never appears.
    /// Asserting the whole folder is absent is the real check, since the
    /// first `index.md` write is what brings a session folder into existence.
    @Test("RecordingLevel.off writes no index.md and no transcript at all")
    @MainActor
    func recordingLevelOffWritesNothing() async throws {
        try await Self.withRouter(recordingLevel: .off) { fixture in
            let root = fixture.profile.standard.makeSession()
            defer { await root.close() }
            _ = try await root.respond(to: "hello")

            #expect(!FileManager.default.fileExists(atPath: fixture.routerDirectory.path))
        }
    }

    // MARK: - Best-effort write failure

    /// A recordings root that is a regular file makes every write under it
    /// fail, the `index.md` and the transcript alike. The failure is best
    /// effort and never reaches `respond()`.
    @Test("a session whose index.md can never be written still generates normally")
    @MainActor
    func sessionWithUnwritableIndexStillGenerates() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempPrefix)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.tempPrefix)-blocker-\(UUID().uuidString)", isDirectory: false)
        try Data().write(to: recordingsDir)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        defer { await root.close() }
        #expect(try await root.respond(to: "hello") == Self.cannedText)
        #expect(try await root.respond(to: "hi") == Self.cannedText)
    }
}
