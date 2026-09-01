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
/// The suite also proves that a supplied string reaches the model. A restore
/// seeds its backend from a reconstructed transcript, and the backend reads
/// its instructions from that transcript's leading `.instructions` entry.
/// ``SeedCapturingContainer`` captures that transcript at the construction
/// seam, so a test reads what the model itself receives. A test that reads
/// ``RoutedSessionActor/instructions`` alone proves nothing about the model.
///
/// Two more tests hold the substitution itself. The substituted entry keeps
/// the recorded entry id and the recorded tool definitions, so a restored
/// session keeps its tool declarations. A turn after a restore appends only
/// that turn's own entries, so an override never enters the recorded
/// `transcript.jsonl`.
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

    /// Records every transcript a restore seeds a model-facing backend from.
    ///
    /// A restore builds its backend through `makeSession(transcript:tools:)`,
    /// which takes no instructions argument. The backend reads its
    /// instructions from that transcript's leading `.instructions` entry. So
    /// this capture is what proves an override reaches the model.
    /// ``RoutedSessionActor/instructions`` alone proves nothing.
    ///
    /// `@unchecked Sendable` is safe here without synchronization:
    /// ``seedTranscripts`` is appended to only synchronously inside
    /// `makeSession(transcript:tools:)` — called from the `restoreSession`
    /// call a `@MainActor` test awaits — and read only after that call returns
    /// to the same test method, so no two tasks ever touch it concurrently.
    private final class SeedCapturingContainer: LoadedLLMContainer, @unchecked Sendable {
        /// Whether a vended session's backend opens with an `.instructions`
        /// entry, the way a live `LanguageModelSession` does. `false` stands
        /// for a recording whose transcript holds no such entry at all.
        let recordsInstructionsEntry: Bool

        /// The tool definitions that entry declares. A live
        /// `LanguageModelSession` states its whole tool roster there, so a
        /// restore must carry the roster into the entry it substitutes.
        let recordedToolDefinitions: [Transcript.ToolDefinition]

        /// Every transcript `makeSession(transcript:tools:)` was given, in
        /// call order.
        private(set) var seedTranscripts: [Transcript] = []

        /// Creates a capturing container.
        ///
        /// - Parameters:
        ///   - recordsInstructionsEntry: Whether a vended session's backend
        ///     opens with an `.instructions` entry.
        ///   - recordedToolDefinitions: The tool definitions that entry
        ///     declares, or empty.
        init(
            recordsInstructionsEntry: Bool,
            recordedToolDefinitions: [Transcript.ToolDefinition] = []
        ) {
            self.recordsInstructionsEntry = recordsInstructionsEntry
            self.recordedToolDefinitions = recordedToolDefinitions
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            guard recordsInstructionsEntry, let instructions else {
                return StubSessionBackend()
            }
            return StubSessionBackend(entries: [
                .instructions(
                    Transcript.Instructions(
                        segments: [.text(Transcript.TextSegment(content: instructions))],
                        toolDefinitions: recordedToolDefinitions))
            ])
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }

        func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
            seedTranscripts.append(transcript)
            return StubSessionBackend(entries: Array(transcript))
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

    /// The prompt the restored session answers. A turn after a restore is what
    /// makes the restored session diff its backend transcript and append to
    /// the recorded file.
    private static let resumedPrompt = "what did I ask you to remember"

    /// The name of the tool the recorded session declared.
    private static let recordedToolName = "search"

    /// The description of the tool the recorded session declared.
    private static let recordedToolDescription = "search the recorded notes"

    /// The arguments ``recordedToolDefinition`` declares.
    @Generable
    struct SearchArguments: Equatable {
        @Guide(description: "The search query.")
        var query: String
    }

    /// The tool definition the recorded session's leading `.instructions`
    /// entry carries.
    ///
    /// A live `LanguageModelSession` states its whole tool roster in that one
    /// entry. An instructions override replaces that entry, so it must carry
    /// the roster across. A restore that drops the roster leaves the model
    /// unable to call any tool, and no error says so.
    private static let recordedToolDefinition = Transcript.ToolDefinition(
        name: recordedToolName,
        description: recordedToolDescription,
        parameters: SearchArguments.generationSchema)

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
    ///   - container: The container both routers load, or the plain stub. Pass
    ///     a ``SeedCapturingContainer`` to read the transcript the restore
    ///     seeds its backend from.
    ///   - answersAPrompt: Whether the root session answers ``recordedPrompt``
    ///     before the restore. `false` records a session that holds no
    ///     transcript entry at all — a session a caller opened and left.
    /// - Returns: The recorded session and the profile to restore it with.
    private static func recordRoot(
        cacheDir: URL,
        recordingsDir: URL,
        instructions: String?,
        workingDirectory: URL? = nil,
        container: any LoadedLLMContainer = BasicLLMContainer(),
        answersAPrompt: Bool = true
    ) async throws -> Recording {
        let recorder = JSONLRecorder(directory: recordingsDir)
        let loader = StubModelLoader(
            container: container, dimension: RouterTestFixtures.stubDimension)

        let recordingRouter = RouterTestFixtures.makeRouter(
            cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder, loader: loader)
        let recordingProfile = try await recordingRouter.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = recordingProfile.standard.makeSession(
            instructions: instructions, workingDirectory: workingDirectory)
        if answersAPrompt {
            _ = try await root.respond(to: recordedPrompt)
        }

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

    /// Every event of one kind that one session recorded.
    ///
    /// - Parameters:
    ///   - id: The session's span id.
    ///   - routerDirectory: The recording root to read.
    ///   - kind: The event kind to keep.
    /// - Returns: The session's events of that kind, in `seq` order.
    private static func recordedEvents(
        session id: ULID, under routerDirectory: URL, ofKind kind: TranscriptEvent.Kind
    ) throws -> [TranscriptEvent] {
        let tree = try TranscriptTree.load(under: routerDirectory)
        return try tree.events(forSession: id).filter { $0.kind == kind }
    }

    /// The kind of every entry-kind event one session recorded, in `seq` order.
    ///
    /// Router-only kinds are dropped, so the result is the recorded transcript
    /// itself. A restore appends a `.divergence` marker, which this read never
    /// reports.
    ///
    /// - Parameters:
    ///   - id: The session's span id.
    ///   - routerDirectory: The recording root to read.
    /// - Returns: The recorded entry kinds, in order.
    private static func recordedEntryKinds(
        session id: ULID, under routerDirectory: URL
    ) throws -> [TranscriptEvent.Kind] {
        let tree = try TranscriptTree.load(under: routerDirectory)
        return try tree.events(forSession: id).map(\.kind).filter(\.isEntryKind)
    }

    /// The leading `.instructions` entry of `transcript`, or `nil`.
    ///
    /// - Parameter transcript: The transcript to read.
    /// - Returns: The entry, or `nil` when the transcript opens otherwise.
    private static func leadingInstructions(
        of transcript: Transcript
    ) -> Transcript.Instructions? {
        guard let first = transcript.first, case .instructions(let instructions) = first else {
            return nil
        }
        return instructions
    }

    /// One instructions substitution, as the recording holds it and as the
    /// restored backend received it.
    private struct SubstitutedInstructions {
        /// The `.instructions` entry payload the recording holds on disk.
        let recorded: TranscriptEntryPayload

        /// The leading `.instructions` entry of the transcript the restored
        /// backend was seeded with.
        let seeded: Transcript.Instructions
    }

    /// Records a root session whose leading `.instructions` entry declares
    /// ``recordedToolDefinition``, then restores it under
    /// ``freshInstructions``.
    ///
    /// - Parameters:
    ///   - cacheDir: The per-test cache directory.
    ///   - recordingsDir: The per-test durable transcripts root.
    /// - Returns: The recorded entry and the entry the restore substituted.
    @MainActor
    private static func substituteInstructionsOnRestore(
        cacheDir: URL, recordingsDir: URL
    ) async throws -> SubstitutedInstructions {
        let container = SeedCapturingContainer(
            recordsInstructionsEntry: true,
            recordedToolDefinitions: [recordedToolDefinition])
        let recording = try await recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: recordedInstructions, container: container)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: freshInstructions)

        let recordedEntries = try recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .instructions)
        let seed = try #require(container.seedTranscripts.last)
        return SubstitutedInstructions(
            recorded: try #require(recordedEntries.first?.entry),
            seeded: try #require(leadingInstructions(of: seed))
        )
    }

    /// Records a root session whose transcript holds no `.instructions` entry,
    /// restores it under ``freshInstructions``, and runs one turn on it.
    ///
    /// The turn is what makes the restored session diff its backend transcript
    /// against the entries it counts as persisted. A restore that undercounts
    /// them writes recorded entries to disk a second time.
    ///
    /// - Parameters:
    ///   - cacheDir: The per-test cache directory.
    ///   - recordingsDir: The per-test durable transcripts root.
    ///   - answersAPrompt: Whether the recording holds one turn of its own
    ///     before the restore.
    /// - Returns: The recording, so a test can read what it now holds on disk.
    @MainActor
    private static func takeOneTurnAfterRestoring(
        cacheDir: URL, recordingsDir: URL, answersAPrompt: Bool
    ) async throws -> Recording {
        let container = SeedCapturingContainer(recordsInstructionsEntry: false)
        let recording = try await recordRoot(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            instructions: nil,
            container: container,
            answersAPrompt: answersAPrompt
        )

        let restored = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: freshInstructions)
        _ = try await restored.session.respond(to: resumedPrompt)
        return recording
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

        let markers = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .divergence)
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

        let markers = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .divergence)
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

        let markers = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .divergence)
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

        let markers = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .divergence)
        let text = try #require(markers.first?.text)
        #expect(text.contains(RestoredSession.instructionsDivergencePhrase))
        #expect(text.contains("recorded \(Self.recordedInstructions.count) characters"))
        #expect(text.contains("supplied \(Self.freshInstructions.count) characters"))
        #expect(!text.contains(Self.recordedInstructions))
        #expect(!text.contains(Self.freshInstructions))
    }

    // MARK: - The override reaches the model

    @Test("instructions that differ reach the transcript the restored backend is seeded from")
    @MainActor
    func differingInstructionsReachTheSeedTranscript() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = SeedCapturingContainer(recordsInstructionsEntry: true)
        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions, container: container)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let seed = try #require(container.seedTranscripts.last)
        #expect(TranscriptDiffer.leadingInstructionsText(of: seed) == Self.freshInstructions)
    }

    @Test("instructions reach the seed transcript of a recording that holds no instructions entry")
    @MainActor
    func instructionsReachTheSeedTranscriptWithNoRecordedEntry() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = SeedCapturingContainer(recordsInstructionsEntry: false)
        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: nil, container: container)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let seed = try #require(container.seedTranscripts.last)
        #expect(TranscriptDiffer.leadingInstructionsText(of: seed) == Self.freshInstructions)
    }

    @Test("no instructions leave the recorded string in the seed transcript")
    @MainActor
    func nilInstructionsLeaveTheSeedTranscriptAlone() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = SeedCapturingContainer(recordsInstructionsEntry: true)
        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions, container: container)

        _ = try await recording.resumingProfile.standard.restoreSession(id: recording.sessionId)

        let seed = try #require(container.seedTranscripts.last)
        #expect(TranscriptDiffer.leadingInstructionsText(of: seed) == Self.recordedInstructions)
    }

    @Test("an instructions override leaves the recorded instructions entry on disk unchanged")
    @MainActor
    func theOverrideDoesNotRewriteTheRecordedEntry() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = SeedCapturingContainer(recordsInstructionsEntry: true)
        let recording = try await Self.recordRoot(
            cacheDir: cacheDir, recordingsDir: recordingsDir,
            instructions: Self.recordedInstructions, container: container)

        _ = try await recording.resumingProfile.standard.restoreSession(
            id: recording.sessionId, instructions: Self.freshInstructions)

        let recorded = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .instructions)
        #expect(recorded.count == 1)
        #expect(recorded.first?.text == Self.recordedInstructions)
    }

    // MARK: - The substitution keeps the recorded entry's identity

    @Test("an instructions override keeps the recorded entry id")
    @MainActor
    func theOverrideKeepsTheRecordedEntryId() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let substitution = try await Self.substituteInstructionsOnRestore(
            cacheDir: cacheDir, recordingsDir: recordingsDir)

        #expect(substitution.seeded.id == substitution.recorded.entryId)
    }

    @Test("an instructions override keeps the recorded tool definitions")
    @MainActor
    func theOverrideKeepsTheRecordedToolDefinitions() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let substitution = try await Self.substituteInstructionsOnRestore(
            cacheDir: cacheDir, recordingsDir: recordingsDir)

        // The recording itself must carry the roster, or the assertion below
        // would hold an empty list against an empty list.
        #expect(substitution.recorded.toolDefinitions?.map(\.name) == [Self.recordedToolName])
        #expect(substitution.seeded.toolDefinitions.map(\.name) == [Self.recordedToolName])
        #expect(
            substitution.seeded.toolDefinitions.map(\.description)
                == [Self.recordedToolDescription])
    }

    // MARK: - A turn after a restore records only that turn

    @Test("a turn after a restore with an override records no instructions event")
    @MainActor
    func aTurnAfterARestoreRecordsNoInstructionsEvent() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.takeOneTurnAfterRestoring(
            cacheDir: cacheDir, recordingsDir: recordingsDir, answersAPrompt: false)

        let recorded = try Self.recordedEvents(
            session: recording.sessionId, under: recording.routerDirectory, ofKind: .instructions)
        #expect(recorded.isEmpty)
    }

    @Test("a turn after a restore with an override records only that turn's entries")
    @MainActor
    func aTurnAfterARestoreRecordsOnlyItsOwnEntries() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: "SessionRestorationTests")
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recording = try await Self.takeOneTurnAfterRestoring(
            cacheDir: cacheDir, recordingsDir: recordingsDir, answersAPrompt: true)

        let kinds = try Self.recordedEntryKinds(
            session: recording.sessionId, under: recording.routerDirectory)
        #expect(kinds == [.prompt, .response, .prompt, .response])
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
