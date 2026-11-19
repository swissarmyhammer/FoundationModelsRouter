import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The import of a session that another agent recorded (D209 (h), part 2):
/// ``RouterSessionDirectory/importSession(_:transcript:)`` writes a new
/// recording from the given transcript with the model of the launcher
/// (``SessionLauncher/importTarget(for:)``), and the directory then holds a
/// recorded root session that is not live, with the origin `import`, the
/// provenance of the request and the name of the request.
///
/// Each test imports through a ``FakeSessionLauncher`` over the stub profile
/// of a router that records durably in a temporary folder. The directory
/// reads the recording root of that router (`useRecordingRoots(_:)`). A test
/// that must show which events an import sends emits one marker event after
/// the import and reads up to it: the read never waits on an event that
/// does not come.
@Suite struct RouterSessionDirectoryImportTests {
    // MARK: - Fixtures

    /// The temp-directory prefix of the folders of the suite, so a leaked
    /// folder names this suite.
    private static let tempDirPrefix = "RouterSessionDirectoryImportTests"

    /// The title of each import request.
    private static let title = "Imported triage"

    /// The name that a second import with ``title`` in the same folder gets:
    /// the slug of the title with the first free number.
    private static let secondName = "imported-triage-2"

    /// The instructions of the imported transcript.
    private static let instructions = "answer in one line"

    /// The number of turns of ``transcript``.
    private static let turnCount = 3

    /// The time of the last record of the source session, in milliseconds
    /// since 1970. The value is a whole millisecond, thus it reads back
    /// equal from the `index.md`.
    private static let sourceLastMilliseconds: Int64 = 1_756_000_000_123

    /// The time of the import, in milliseconds since 1970.
    private static let importedAtMilliseconds: Int64 = 1_756_000_360_456

    /// The number of records of the source that the import did not read.
    private static let skippedRecordCount = 2

    /// The provenance of each import request.
    private static let provenance = SessionImportProvenance(
        agent: "claude-code",
        sourceID: "source-session-1",
        sourcePath: "/Users/dev/.claude/projects/example/source-session-1.jsonl",
        sourceLastDate: DateTime(millisecondsSince1970: sourceLastMilliseconds).date,
        importedAt: DateTime(millisecondsSince1970: importedAtMilliseconds).date,
        skippedRecordCount: skippedRecordCount)

    /// A transcript of three turns: the instructions, then a prompt and a
    /// response for each turn.
    private static let transcript = Transcript(
        entries: [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: []))
        ]
            + (0..<turnCount).flatMap { turn -> [Transcript.Entry] in
                [
                    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "question \(turn)"))])),
                    .response(
                        Transcript.Response(segments: [.text(Transcript.TextSegment(content: "answer \(turn)"))])),
                ]
            })

    /// The marker event a test emits after the import, so the read of the
    /// events ends there.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    /// A router that records durably, a launcher over its profile, and the
    /// folders of the test.
    struct Fixture {
        /// The temporary folder of the test. It holds ``recordingRoot`` and
        /// ``workingDirectory``.
        let folder: URL

        /// The router that resolved the profile of ``launcher``. It owns
        /// ``directory``.
        let router: Router

        /// The launcher that gives the model of each import.
        let launcher: FakeSessionLauncher

        /// The recording root of ``router``: the folder that holds each
        /// session folder that it writes.
        let recordingRoot: URL

        /// The working folder of each import request.
        var workingDirectory: URL {
            folder.appendingPathComponent("work", isDirectory: true)
        }

        /// The directory under test: the router's own.
        var directory: RouterSessionDirectory { router.sessionDirectory }

        /// Makes the router over a durable recording root whose recorder is
        /// `recorder`, a launcher over its profile, and gives both the
        /// launcher and the recording root to the directory.
        ///
        /// - Parameter recorder: The recorder of the router, or `nil` (the
        ///   default) for a recorder that writes JSONL files.
        /// - Returns: The fixture.
        /// - Throws: The error of the resolve of the profile.
        static func make(recorder: (any TranscriptRecorder)? = nil) async throws -> Fixture {
            let folder = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
            let recordingsDir = folder.appendingPathComponent("recordings", isDirectory: true)
            let router = RouterTestFixtures.makeRouter(
                cacheDir: folder.appendingPathComponent("cache", isDirectory: true),
                recordingsDir: recordingsDir, recorder: recorder ?? JSONLRecorder(directory: recordingsDir),
                loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let recordingRoot = RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir)
            let launcher = FakeSessionLauncher(profile: profile)
            await router.sessionDirectory.use(launcher: launcher)
            await router.sessionDirectory.useRecordingRoots { [recordingRoot] }
            return Fixture(folder: folder, router: router, launcher: launcher, recordingRoot: recordingRoot)
        }

        /// The import request of each test: ``title``, ``provenance`` and
        /// ``workingDirectory``, with no agent.
        var request: SessionImportRequest {
            SessionImportRequest(workingDirectory: workingDirectory, title: title, provenance: provenance)
        }

        /// Imports ``transcript`` with ``request``.
        ///
        /// - Returns: The summary that the import gives.
        /// - Throws: The error of the import.
        func importSession() async throws -> SessionSummary {
            try await directory.importSession(request, transcript: transcript)
        }

        /// The summary of `id` that the recorded sessions of the directory
        /// give, with `includesRecorded`.
        ///
        /// - Parameter id: A session id.
        /// - Returns: The summary, or `nil` when the list has no session `id`.
        /// - Throws: The error of the list.
        func listed(_ id: ULID) async throws -> SessionSummary? {
            try await directory.sessions(matching: SessionQuery(includesRecorded: true)).first { $0.id == id }
        }

        /// The names of the entries of ``recordingRoot``, or none when the
        /// root does not exist.
        var recordingRootEntries: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: recordingRoot.path)) ?? []
        }

        /// Closes each session of the launcher, shuts the directory down and
        /// removes the temporary folder.
        func tearDown() async {
            await launcher.closeSessions()
            await directory.shutdown()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Makes a fixture, runs `body` with it, and tears it down, also when
    /// `body` throws.
    ///
    /// - Parameters:
    ///   - recorder: The recorder of the router, or `nil` (the default) for
    ///     a recorder that writes JSONL files.
    ///   - body: The work of the test.
    /// - Throws: What the fixture or `body` throws.
    private static func withFixture(
        recorder: (any TranscriptRecorder)? = nil, _ body: (Fixture) async throws -> Void
    ) async throws {
        let fixture = try await Fixture.make(recorder: recorder)
        do {
            try await body(fixture)
            await fixture.tearDown()
        } catch {
            await fixture.tearDown()
            throw error
        }
    }

    // MARK: - Restore

    /// The production change that makes this test fail: an import that
    /// writes no recording, or a recording that the restore does not read
    /// back as the given transcript.
    @Test func anImportRestoresToTheGivenTranscript() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()

            let restored = try await fixture.launcher.restoreSession(id: imported.id)

            #expect(await restored.transcript == Self.transcript)
        }
    }

    /// The production change that makes this test fail: an import that
    /// records another origin than `import`.
    @Test func aRestoredImportHasTheImportOrigin() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()
            _ = try await fixture.launcher.restoreSession(id: imported.id)

            let summary = try #require(try await fixture.directory.summary(of: imported.id))

            #expect(summary.origin == .import)
        }
    }

    /// The production change that makes this test fail: a live summary that
    /// does not give the provenance of the facts.
    @Test func aRestoredImportGivesItsProvenance() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()
            _ = try await fixture.launcher.restoreSession(id: imported.id)

            let summary = try #require(try await fixture.directory.summary(of: imported.id))

            #expect(summary.importedFrom == Self.provenance)
        }
    }

    /// The production change that makes this test fail: an import that
    /// writes a record with a fork parent or a spawn.
    @Test func aRestoredImportIsARootSession() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()
            _ = try await fixture.launcher.restoreSession(id: imported.id)

            let summary = try #require(try await fixture.directory.summary(of: imported.id))

            #expect(summary.kind == .root)
        }
    }

    // MARK: - The summary of the import

    /// The production change that makes this test fail: an import that
    /// makes the session live, or gives a summary that is not the recorded
    /// summary of the new session.
    @Test func theImportGivesTheRecordedSummaryOfAnIdleRootThatIsNotLive() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()

            let listed = try await fixture.listed(imported.id)

            #expect(listed == imported)
            #expect(!imported.isLive)
            #expect(imported.state == .idle)
            #expect(imported.kind == .root)
        }
    }

    /// The production change that makes this test fail: an import that
    /// writes the session with the folder of the launcher, not the folder of
    /// the request.
    @Test func theImportHasTheFolderOfTheRequest() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()

            #expect(
                RouterSessionDirectory.comparablePath(of: imported.workingDirectory)
                    == RouterSessionDirectory.comparablePath(of: fixture.workingDirectory))
        }
    }

    // MARK: - After a restart

    /// The production change that makes this test fail: an encode of the
    /// record that does not write the provenance, so a new directory over
    /// the same recording root reads no provenance.
    @Test func anImportGivesItsProvenanceAfterARestart() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()
            let restarted = Router(pool: ModelPool()).sessionDirectory
            await restarted.useRecordingRoots { [fixture.recordingRoot] }

            let summary = try #require(try await restarted.summary(of: imported.id))

            #expect(summary.importedFrom == Self.provenance)
            #expect(summary.origin == .import)
        }
    }

    // MARK: - The name

    /// The production change that makes this test fail: an import that
    /// gives the session no title, or the default name of its agent.
    @Test func theListShowsTheImportWithTheTitleOfTheRequest() async throws {
        try await Self.withFixture { fixture in
            let imported = try await fixture.importSession()

            let listed = try #require(try await fixture.listed(imported.id))

            #expect(listed.title == Self.title)
        }
    }

    /// The production change that makes this test fail: a name rule that
    /// does not count the first import, so the second import gets the same
    /// name.
    @Test func aSecondImportWithTheSameTitleGetsTheNextFreeNumber() async throws {
        try await Self.withFixture { fixture in
            _ = try await fixture.importSession()

            let second = try await fixture.importSession()

            #expect(second.title == Self.secondName)
        }
    }

    /// The production change that makes this test fail: a name rule that
    /// counts an archived session, as the in-memory directory of Extras
    /// does not.
    @Test func anArchivedSessionDoesNotHoldTheName() async throws {
        try await Self.withFixture { fixture in
            let first = try await fixture.importSession()
            _ = try await fixture.directory.archive(first.id, by: .user(clientID: Self.tempDirPrefix))

            let second = try await fixture.importSession()

            #expect(second.title == Self.title)
        }
    }

    /// The production change that makes this test fail: an import that
    /// opens the session of an earlier import with the same source (Q85
    /// (c)).
    @Test func eachImportMakesANewSession() async throws {
        try await Self.withFixture { fixture in
            let first = try await fixture.importSession()

            let second = try await fixture.importSession()

            #expect(second.id != first.id)
        }
    }

    // MARK: - Events

    /// The production change that makes this test fail: an import that
    /// sends `started`, sends no event, or sends `factsChanged` more than
    /// one time.
    @Test func anImportSendsOneFactsChangedAndNoStarted() async throws {
        try await Self.withFixture { fixture in
            var events = fixture.directory.events().makeAsyncIterator()

            let imported = try await fixture.importSession()
            fixture.directory.emit(Self.marker)
            let received = await events.next(through: Self.marker)

            #expect(received == [.factsChanged(imported), Self.marker])
        }
    }

    // MARK: - A failed write

    /// The production change that makes this test fail: an import that
    /// leaves the folder of a write that failed in the recording root.
    @Test func aFailedWriteLeavesNoFolder() async throws {
        try await Self.withFixture(recorder: NoneRecorder()) { fixture in
            _ = try? await fixture.importSession()

            #expect(fixture.recordingRootEntries.isEmpty)
        }
    }

    /// The production change that makes this test fail: an import that
    /// does not give the error of the write to its caller.
    @Test func aFailedWriteThrows() async throws {
        try await Self.withFixture(recorder: NoneRecorder()) { fixture in
            await #expect(throws: SessionRecordingWriteError.self) {
                try await fixture.importSession()
            }
        }
    }

    /// The production change that makes this test fail: an import that
    /// adds the session to the directory before the write ends.
    @Test func aFailedWriteLeavesNoDirectoryEntry() async throws {
        try await Self.withFixture(recorder: NoneRecorder()) { fixture in
            _ = try? await fixture.importSession()

            let listed = try await fixture.directory.sessions(matching: SessionQuery(includesRecorded: true))

            #expect(listed.isEmpty)
        }
    }

    /// The production change that makes this test fail: an import that
    /// sends an event for a session that it did not write.
    @Test func aFailedWriteSendsNoEvent() async throws {
        try await Self.withFixture(recorder: NoneRecorder()) { fixture in
            var events = fixture.directory.events().makeAsyncIterator()

            _ = try? await fixture.importSession()
            fixture.directory.emit(Self.marker)
            let received = await events.next(through: Self.marker)

            #expect(received == [Self.marker])
        }
    }

    // MARK: - The launcher

    /// The production change that makes this test fail: an import that
    /// writes with no launcher.
    @Test func anImportWithNoLauncherThrowsNoLauncher() async throws {
        try await Self.withFixture { fixture in
            await fixture.directory.shutdown()

            await #expect(throws: SessionDirectoryError.noLauncher) {
                try await fixture.importSession()
            }
        }
    }

    /// A launcher that refuses each start and each restore and gives no
    /// import operation of its own.
    struct NoImportLauncher: StartRefusingLauncher {}

    /// The production change that makes this test fail: a default of the
    /// launcher port that gives a model, or an import that writes with no
    /// model of the launcher.
    @Test func aLauncherWithNoImportOperationRefusesTheImport() async throws {
        try await Self.withFixture { fixture in
            await fixture.directory.use(launcher: NoImportLauncher())

            await #expect(throws: SessionDirectoryError.importUnsupported) {
                try await fixture.importSession()
            }
        }
    }
}
