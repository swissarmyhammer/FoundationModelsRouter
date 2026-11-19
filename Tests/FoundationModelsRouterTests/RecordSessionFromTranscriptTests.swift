import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedModel/recordSession(from:configuration:)`` (D209 (h),
/// part 1): a host writes a new session recording from a model transcript
/// that it gives, with no live session, and the normal restore opens it.
///
/// The suite proves that the restore gives the given transcript and a root
/// session, that the record reads back, that the restore gives the recorded
/// compaction budget and that a transcript over that budget compacts at the
/// first answer, and that a write that fails leaves no folder.
///
/// Everything runs against the stub profile of the tests and a durable
/// recording root in a temporary folder, so the suite needs no network and no
/// GPU.
@Suite("Session recording from a transcript: recordSession(from:configuration:)")
struct RecordSessionFromTranscriptTests {
    // MARK: - Fixtures

    /// The temp-directory prefix of the folders of the suite, so a leaked
    /// folder names this suite.
    private static let tempDirPrefix = "RecordSessionFromTranscriptTests"

    /// The instructions of the given transcript and of its configuration.
    private static let instructions = "answer in one line"

    /// The title of the written session.
    private static let title = "Imported triage"

    /// The agent id of the written session.
    private static let agentID = "default"

    /// The prompt of the first answer after a restore.
    private static let nextPrompt = "and what next"

    /// The number of turns of ``threeTurnTranscript``.
    private static let turnCount = 3

    /// The factor that makes the limit of a budget much larger than the
    /// transcript, so that the transcript stays under the trigger.
    private static let roomyBudgetFactor = 100

    /// A transcript of three turns: the instructions, then a prompt and a
    /// response for each turn.
    private static let threeTurnTranscript = Transcript(
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

    /// The name of the tool of ``toolTranscript``.
    private static let toolName = "search"

    /// The id of the tool call of ``toolTranscript``.
    private static let toolCallID = "call-1"

    /// The grammar source of a guided written session.
    private static let grammarSource = #"{"type":"object"}"#

    /// A transcript of one turn with a tool: the instructions, a prompt, a
    /// tool-call entry, a tool-output entry and the response after them.
    ///
    /// The arguments of the call are built from properties, the form of the
    /// arguments of a live call, so a restored call compares equal.
    private static let toolTranscript = Transcript(
        entries: [
            .instructions(
                Transcript.Instructions(
                    segments: [.text(Transcript.TextSegment(content: instructions))], toolDefinitions: [])),
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "what is the weather"))])),
            .toolCalls(
                Transcript.ToolCalls([
                    Transcript.ToolCall(
                        id: toolCallID, toolName: toolName,
                        arguments: GeneratedContent(properties: ["query": "weather"]))
                ])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: toolCallID, toolName: toolName,
                    segments: [.text(Transcript.TextSegment(content: "sunny, 72F"))])),
            .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: "it is sunny"))])),
        ])

    /// The configuration of each written session of the suite.
    ///
    /// - Parameters:
    ///   - budget: The compaction budget, or `nil` for none.
    ///   - grammar: The grammar of the session, or `nil` for none.
    /// - Returns: The configuration.
    private static func configuration(budget: TokenBudget? = nil, grammar: Grammar? = nil) -> SessionConfiguration {
        SessionConfiguration(
            instructions: instructions,
            compaction: CompactionSettings(budget: budget),
            grammar: grammar,
            agentID: agentID,
            title: title,
            origin: .client)
    }

    /// Restores the session `id` over `profile`, runs `body` with it, and
    /// closes it, also when `body` throws.
    ///
    /// - Parameters:
    ///   - id: The id of the written session.
    ///   - profile: The profile to restore over.
    ///   - body: The work to run with the restored session.
    /// - Returns: What `body` returns.
    /// - Throws: What the restore or `body` throws.
    private static func withRestored<Value>(
        _ id: ULID, over profile: LanguageModelProfile,
        _ body: (any RoutedSession) async throws -> Value
    ) async throws -> Value {
        let restored = try await profile.standard.restoreSession(id: id)
        do {
            let value = try await body(restored.session)
            await SessionFixtureLifecycle.close([restored.session])
            return value
        } catch {
            await SessionFixtureLifecycle.close([restored.session])
            throw error
        }
    }

    /// Resolves the stub profile over a durable recording root whose
    /// recorder is `recorder`, and runs `body` with the profile and the
    /// recording root of the router. The temporary folder goes after.
    ///
    /// - Parameters:
    ///   - recorder: The recorder of the router.
    ///   - body: The work to run.
    /// - Throws: What the resolve or `body` throws.
    private static func withRouter(
        recorder: any TranscriptRecorder,
        _ body: (LanguageModelProfile, URL) async throws -> Void
    ) async throws {
        let folder = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recordingsDir = folder.appendingPathComponent("recordings", isDirectory: true)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: folder.appendingPathComponent("cache", isDirectory: true),
            recordingsDir: recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        try await body(
            profile, RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: recordingsDir))
    }

    // MARK: - Restore

    @Test("a written recording of three turns restores to the given transcript")
    func aWrittenRecordingRestoresToTheGivenTranscript() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let id = try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())

            let restored = try await Self.withRestored(id, over: profile) { await $0.transcript }

            #expect(restored == Self.threeTurnTranscript)
        }
    }

    @Test("a written recording with a tool call and a tool output restores to the given transcript")
    func aWrittenRecordingWithToolEntriesRestoresToTheGivenTranscript() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let id = try await profile.standard.recordSession(
                from: Self.toolTranscript, configuration: Self.configuration())

            let restored = try await Self.withRestored(id, over: profile) { await $0.transcript }

            #expect(restored == Self.toolTranscript)
        }
    }

    @Test("a written recording of a guided session stamps the grammar on each event, as a live session does")
    func aWrittenGuidedRecordingStampsTheGrammarOnEachEvent() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let handle = profile.standard
            let id = try await handle.recordSession(
                from: Self.threeTurnTranscript,
                configuration: Self.configuration(grammar: .jsonSchema(Self.grammarSource)))

            let events = try JSONLFile(
                url: handle.recordingDirectory(forSessionId: id)
                    .appendingPathComponent(transcriptFileName, isDirectory: false)
            ).records(as: TranscriptEvent.self)

            #expect(Set(events.map(\.grammar)) == [Self.grammarSource])
        }
    }

    @Test("a written recording restores as a root session")
    func aWrittenRecordingRestoresAsARoot() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let directory = try #require(profile.standard.sessionDirectory)
            let id = try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())

            let summary = try await Self.withRestored(id, over: profile) {
                try await SessionDirectorySummaries.summary(of: $0.id, in: directory)
            }

            #expect(summary.kind == .root)
        }
    }

    @Test("the record of a written recording reads back with the facts and the model of the handle")
    func theRecordOfAWrittenRecordingReadsBack() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let handle = profile.standard
            let id = try await handle.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())

            let record = try #require(try SessionIndexFile.read(in: handle.recordingDirectory(forSessionId: id)))

            #expect(record.facts == SessionFacts(agentID: Self.agentID, title: Self.title, origin: .client))
            #expect(record.sessionId == id)
            #expect(record.slot == handle.slot)
            #expect(record.model == handle.chosen)
            #expect(record.instructions == Self.instructions)
            #expect(record.schemaVersion == RecordingSchemaVersion.current)
            #expect(record.profile == handle.durableRecording?.indexWriter.profile)
        }
    }

    // MARK: - Compaction

    @Test("a written transcript over the budget compacts at the first answer after the restore")
    func aTranscriptOverTheBudgetCompactsAtTheFirstAnswer() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let budget = summarizingCompactionBudget(for: Array(Self.threeTurnTranscript))
            let id = try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration(budget: budget))

            let events = try await Self.withRestored(id, over: profile) {
                try await collectEvents($0, prompt: Self.nextPrompt)
            }

            #expect(events.compactionResults.count == 1)
        }
    }

    @Test("a written transcript under the budget does not compact at the first answer after the restore")
    func aTranscriptUnderTheBudgetDoesNotCompact() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let budget = TokenBudget(
                limit: characterCount(of: Array(Self.threeTurnTranscript)) * Self.roomyBudgetFactor)
            let id = try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration(budget: budget))

            let events = try await Self.withRestored(id, over: profile) {
                try await collectEvents($0, prompt: Self.nextPrompt)
            }

            #expect(events.compactionResults.isEmpty)
        }
    }

    // MARK: - A failed write

    @Test("a write whose events do not reach the disk throws")
    func aWriteWhoseEventsAreDroppedThrows() async throws {
        try await Self.withRouter(recorder: NoneRecorder()) { profile, _ in
            await #expect(throws: SessionRecordingWriteError.self) {
                try await profile.standard.recordSession(
                    from: Self.threeTurnTranscript, configuration: Self.configuration())
            }
        }
    }

    @Test("a write whose events do not reach the disk leaves no folder and no temporary folder")
    func aFailedWriteLeavesNoFolder() async throws {
        try await Self.withRouter(recorder: NoneRecorder()) { profile, recordingRoot in
            _ = try? await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())

            let left = (try? FileManager.default.contentsOfDirectory(atPath: recordingRoot.path)) ?? []
            #expect(left.isEmpty)
        }
    }

    @Test("a temporary folder that a stopped write left in the recording root does not stop a load of the root")
    func aLeftTemporaryFolderDoesNotStopALoad() async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: Self.tempDirPrefix) { profile in
            let id = try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())
            let written = profile.standard.recordingDirectory(forSessionId: id)
            let recordingRoot = written.deletingLastPathComponent()
            // A stop of the process after the files and before the rename
            // leaves the whole temporary folder.
            try FileManager.default.moveItem(at: written, to: RoutedLLM.temporaryFolder(of: written))

            #expect(try TranscriptTree.load(under: recordingRoot).roots.isEmpty)
        }
    }

    @Test("a handle with no durable recording root refuses the write")
    func aHandleWithNoDurableRootRefusesTheWrite() async throws {
        let folder = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: folder)

        await #expect(throws: SessionRecordingWriteError.noDurableRecording) {
            try await profile.standard.recordSession(
                from: Self.threeTurnTranscript, configuration: Self.configuration())
        }
        withExtendedLifetime(router) {}
    }
}
