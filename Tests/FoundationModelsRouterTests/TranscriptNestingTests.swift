import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises milestone 10a: the core recording behavior over the substrate —
/// lineage-nested transcript directories that mirror the fork tree, rich
/// provenance events at the `generate` chokepoint (a first-line `session` meta
/// event plus `prompt`/`response`), a globally monotonic `seq` across concurrent
/// appends from many sessions/forks, and the router manifest.
///
/// Everything runs against stubs — a stub ``ModelLoader``, a canned LLM
/// container that returns fixed text, and either a ``JSONLRecorder`` writing into
/// a temp directory or an ``InMemoryRecorder`` — so the suite needs no network
/// and no GPU. The cross-file merged view and redaction/level gating are
/// milestone 10b and are not exercised here.
@Suite("Transcript nesting + events + manifest")
struct TranscriptNestingTests {
    // MARK: - Stub containers

    /// A stand-in for a loaded LLM container that returns canned text, no MLX.
    ///
    /// Forwards `instructions` into the backend's synthetic transcript when
    /// `forwardInstructions` is set, so a test can model a session whose SDK
    /// transcript opens with a leading `.instructions` entry the way a real
    /// `LanguageModelSession` given instructions would.
    private struct CannedLLMContainer: PlainTranscriptStubContainer {
        let text: String
        var forwardInstructions = false

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: text, instructions: forwardInstructions ? instructions : nil)
        }
    }

    /// A stand-in for a loaded embedder container, no MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` that returns canned containers with no download or GPU.
    private struct StubModelLoader: ModelLoader {
        let dimension: Int
        let text: String
        var forwardInstructions = false

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return CannedLLMContainer(text: text, forwardInstructions: forwardInstructions)
        }

        func loadEmbedder(
            ref: ModelRef,
            slot: ModelSlot,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedEmbeddingContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return StubEmbeddingContainer(dimension: dimension)
        }

        func preload(container: any LoadedModelContainer) async throws {}
    }

    // MARK: - Fixtures

    private static let configJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data("""
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// `config.json` declaring an explicit `max_position_embeddings` (32768)
    /// rather than falling back to ``RepoMetadata/defaultNativeMaxContext``
    /// (8192) — so a `context: nil` profile's ladder derivation settles on a
    /// figure distinguishable from both the explicit-context default and the
    /// no-fields-present fallback.
    private static let configJSONWithNativeMax32768 = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128,
            "max_position_embeddings": 32768
        }
        """.utf8)

    private static var rawMetadataWithNativeMax32768: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSONWithNativeMax32768, treeJSON: treeJSON)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    /// A profile with `context: nil`, so resolution derives the working
    /// context via ``JointFit``'s ladder instead of using an authored figure.
    private static let profileWithDerivedContext = ProfileDefinition(
        name: "coding-derived",
        description: "test profile with ladder-derived context",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"],
        context: nil
    )

    private static let stubDimension = 8
    private static let cannedText = "canned response"

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptNestingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Builds a router wired with the stubs, an explicit recorder, and a durable
    /// recordings root (so vended sessions nest their transcripts under it).
    ///
    /// - Parameter forwardInstructions: When `true`, a vended session's
    ///   instructions flow into its ``StubSessionBackend``'s synthetic
    ///   transcript as a leading `.instructions` entry, modeling an
    ///   instructed real `LanguageModelSession`.
    private static func makeRouter(
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL,
        forwardInstructions: Bool = false
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(dimension: stubDimension, text: cannedText, forwardInstructions: forwardInstructions)
        )
    }

    /// Decodes every event from a session directory's `transcript.jsonl`.
    private func events(in directory: URL) throws -> [TranscriptEvent] {
        let fileURL = directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
    }

    // MARK: - Lineage-nested directories

    @Test("a fork's transcript is physically nested under its parent's; depth mirrors the fork lineage")
    @MainActor
    func forkTranscriptsNestUnderParent() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
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
        let fork = try await root.fork(workingDirectory: nil)
        let grandfork = try await fork.fork(workingDirectory: nil)

        // The parentId chain mirrors the lineage.
        #expect(root.parentId == nil)
        #expect(fork.parentId == root.id)
        #expect(grandfork.parentId == fork.id)

        // The root nests under <recordingsDir>/<routerId>/<rootId>.
        let expectedRoot = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent(root.id.description, isDirectory: true)
        #expect(root.recordingDirectory.standardizedFileURL == expectedRoot.standardizedFileURL)

        // Each fork nests one level deeper, directly under its parent's directory.
        #expect(
            fork.recordingDirectory.standardizedFileURL
                == root.recordingDirectory.appendingPathComponent(fork.id.description, isDirectory: true).standardizedFileURL
        )
        #expect(
            grandfork.recordingDirectory.standardizedFileURL
                == fork.recordingDirectory.appendingPathComponent(grandfork.id.description, isDirectory: true).standardizedFileURL
        )

        // Each session writes its own transcript.jsonl at its nested path.
        _ = try await root.respond(to: "root")
        _ = try await fork.respond(to: "fork")
        _ = try await grandfork.respond(to: "grandfork")

        for session in [root, fork, grandfork] {
            let fileURL = session.recordingDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }

        _ = grandfork
    }

    @Test("overriding workingDirectory does not move the transcript out of the lineage nesting")
    @MainActor
    func workingDirectoryOverrideDoesNotMoveTranscript() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
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
        let custom = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: custom) }

        let fork = try await root.fork(workingDirectory: custom)

        // The override sets the working directory but does not move the transcript,
        // which stays nested under the parent regardless.
        #expect(fork.workingDirectory.standardizedFileURL == custom.standardizedFileURL)
        #expect(
            fork.recordingDirectory.standardizedFileURL
                == root.recordingDirectory.appendingPathComponent(fork.id.description, isDirectory: true).standardizedFileURL
        )
        #expect(fork.recordingDirectory.standardizedFileURL != custom.standardizedFileURL)

        _ = root
    }

    // MARK: - Event emission

    @Test("a session's first line is the session meta event, then prompt and response with provenance")
    @MainActor
    func firstLineIsSessionMetaThenTurn() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
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
        _ = try await root.respond(to: "hello")

        let recorded = try events(in: root.recordingDirectory)
        #expect(recorded.map(\.kind) == [.session, .prompt, .response])

        // Full provenance is stamped onto every event.
        #expect(recorded.allSatisfy { $0.routerId == router.id })
        #expect(recorded.allSatisfy { $0.sessionId == root.id })
        #expect(recorded.allSatisfy { $0.parentId == nil })
        #expect(recorded.allSatisfy { $0.slot == .standard })
        #expect(recorded.allSatisfy { $0.model == profile.standard.chosen })
        // The recorder assigns a contiguous seq within the file.
        #expect(recorded.map(\.seq) == [0, 1, 2])

        // A fork's first line carries the parentId lineage.
        let fork = try await root.fork(workingDirectory: nil)
        _ = try await fork.respond(to: "child")
        let childRecorded = try events(in: fork.recordingDirectory)
        #expect(childRecorded.first?.kind == .session)
        #expect(childRecorded.allSatisfy { $0.parentId == root.id })

        _ = fork
    }

    @Test("a streaming session's first line is also the session meta event, then prompt and response")
    @MainActor
    func streamResponseFirstLineIsSessionMetaThenTurn() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
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

        // Mirrors firstLineIsSessionMetaThenTurn's root-session assertions but
        // drives the turn through streamResponse(to:) instead of respond(to:):
        // recordSessionMetaIfNeeded() applies to both generation entry points,
        // so the invariant must hold for streaming too.
        let root = profile.standard.makeSession()
        for try await _ in await root.streamResponse(to: "hello") {}

        let recorded = try events(in: root.recordingDirectory)
        #expect(recorded.map(\.kind) == [.session, .prompt, .response])
        #expect(recorded.allSatisfy { $0.routerId == router.id })
        #expect(recorded.allSatisfy { $0.sessionId == root.id })
        #expect(recorded.allSatisfy { $0.parentId == nil })
        #expect(recorded.allSatisfy { $0.slot == .standard })
        #expect(recorded.allSatisfy { $0.model == profile.standard.chosen })
        #expect(recorded.map(\.seq) == [0, 1, 2])
    }

    @Test("an instructed session's first turn opens with an .instructions entry before .prompt/.response")
    @MainActor
    func instructedSessionRecordsLeadingInstructionsEntry() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            forwardInstructions: true
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession(instructions: "You are terse.")
        _ = try await root.respond(to: "hello")

        // The chokepoint no longer hand-builds a `.prompt`/`.response` pair —
        // it persists whatever the SDK's real transcript actually accumulated.
        // Here that's the stub's synthesized `.instructions` entry (seeded from
        // the session's instructions) plus this turn's `.prompt`/`.response`,
        // so the entry-derived sequence gains a case the old hand-built bracket
        // never recorded at all.
        let recorded = try events(in: root.recordingDirectory)
        #expect(recorded.map(\.kind) == [.session, .instructions, .prompt, .response])
        #expect(recorded.allSatisfy { $0.entry != nil || $0.kind == .session })
    }

    @Test("an instructed streaming session's first turn also opens with an .instructions entry before .prompt/.response")
    @MainActor
    func streamResponseInstructedSessionRecordsLeadingInstructionsEntry() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Self.makeRouter(
            recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            forwardInstructions: true
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // Mirrors instructedSessionRecordsLeadingInstructionsEntry but drives
        // the turn through streamResponse(to:): the snapshot-diff persistence
        // and entry mapping in recordTranscriptDelta() apply equally to
        // streaming, so the SDK-generated leading `.instructions` entry must
        // be persisted in order there too.
        let root = profile.standard.makeSession(instructions: "You are terse.")
        for try await _ in await root.streamResponse(to: "hello") {}

        let recorded = try events(in: root.recordingDirectory)
        #expect(recorded.map(\.kind) == [.session, .instructions, .prompt, .response])
        #expect(recorded.allSatisfy { $0.entry != nil || $0.kind == .session })
    }

    // MARK: - Default recorder wiring

    /// This test verifies that a Router without an explicit recorder defaults to a real JSONLRecorder.
    ///
    /// Unlike every other test in this file, this router is built directly
    /// (not through ``makeRouter(recorder:cacheDir:recordingsDir:)``) with no
    /// explicit `recorder:` — only `recordingsDir` — so the real
    /// `Router.defaultRecorder(recordingsDir:)` wiring picks a live
    /// `JSONLRecorder` under it, rather than a test double standing in for it.
    @Test("a Router given recordingsDir but no explicit recorder defaults to a real JSONLRecorder")
    @MainActor
    func defaultRecorderWiresRealJSONLRecorder() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let router = Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadata),
            loader: StubModelLoader(dimension: Self.stubDimension, text: Self.cannedText)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        let root = profile.standard.makeSession()
        _ = try await root.respond(to: "hello")

        // A real JSONLRecorder was wired: the session's transcript.jsonl exists
        // under the router's recordingsDir with real, decodable events — not the
        // no-op wiring that `recordingsDir: nil` would have produced.
        let fileURL = root.recordingDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(
            fileURL.standardizedFileURL.path.hasPrefix(recordingsDir.standardizedFileURL.path)
        )

        let recorded = try events(in: root.recordingDirectory)
        #expect(recorded.map(\.kind) == [.session, .prompt, .response])
        #expect(recorded.allSatisfy { $0.routerId == router.id })
        #expect(recorded.allSatisfy { $0.sessionId == root.id })
    }

    // MARK: - Monotonic seq

    @Test("seq is monotonic across concurrent appends from multiple sessions and forks")
    @MainActor
    func seqMonotonicAcrossConcurrentSessions() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let recorder = InMemoryRecorder()
        let router = Self.makeRouter(
            recorder: recorder,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())

        // A root and three forks — four sessions sharing one recorder.
        let root = profile.standard.makeSession()
        let fork1 = try await root.fork(workingDirectory: nil)
        let fork2 = try await root.fork(workingDirectory: nil)
        let fork3 = try await root.fork(workingDirectory: nil)
        let sessions: [RoutedSession] = [root, fork1, fork2, fork3]

        // Each session concurrently appends many events to the shared recorder,
        // each routed to its own lineage-nested directory.
        let perSession = 100
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                let dir = session.recordingDirectory
                let partial = TranscriptEvent.Partial(
                    routerId: session.routerId,
                    sessionId: session.id,
                    parentId: session.parentId,
                    kind: .prompt
                )
                for _ in 0..<perSession {
                    group.addTask {
                        await recorder.append(partial, to: dir)
                    }
                }
            }
        }

        let events = await recorder.events
        #expect(events.count == sessions.count * perSession)
        // A single recorder means one totally-ordered log: seq is 0..<n, no gaps
        // or duplicates, regardless of interleaving.
        #expect(events.map(\.seq) == Array(0..<events.count))

        _ = sessions
    }

    // MARK: - Manifest

    @Test("the router writes a manifest recording config, resolved profiles, and start/end")
    @MainActor
    func manifestRecordsConfigProfilesAndSpan() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
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

        let manifestURL = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RouterManifest.self, from: data)

        #expect(manifest.routerId == router.id)
        #expect(manifest.config.maxConcurrentForks == 4)
        #expect(manifest.config.recordingLevel == .full)
        #expect(manifest.profiles.count == 1)
        #expect(manifest.profiles.first?.definitionName == "coding")
        #expect(manifest.profiles.first?.standard == profile.standard.chosen)
        #expect(manifest.profiles.first?.flash == profile.flash.chosen)
        #expect(manifest.profiles.first?.embedding == profile.embedding.chosen)
        // `Self.profile` uses the default explicit context (8192), so the
        // ladder never runs and the manifest records that figure verbatim.
        #expect(manifest.profiles.first?.context == 8192)
        #expect(manifest.start <= manifest.end)

        _ = profile
    }

    @Test("a manifest recording a ladder-derived context round-trips through disk")
    @MainActor
    func manifestRecordsLadderDerivedContext() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        // Built directly (not through makeRouter(recorder:cacheDir:recordingsDir:))
        // so the metadata source can be swapped for one whose config.json
        // declares a native max context (32768) instead of the shared
        // fixture's implicit 8192 default — triggering the ladder to settle
        // on a figure distinguishable from the explicit-context test above.
        let router = Router(
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: JSONLRecorder(directory: recordingsDir),
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: Self.rawMetadataWithNativeMax32768),
            loader: StubModelLoader(dimension: Self.stubDimension, text: Self.cannedText)
        )
        // `profileWithDerivedContext` has `context: nil`, so JointFit derives
        // the working context via the ladder instead of using an authored figure.
        let profile = try await router.resolve(profile: Self.profileWithDerivedContext, reporting: ResolutionProgress())

        let manifestURL = recordingsDir
            .appendingPathComponent(router.id.description, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(RouterManifest.self, from: data)

        // The tiny fixture model's footprint is trivial next to the 48 GB
        // budget at any rung, so the ladder settles on the candidate's own
        // native max context (32768) at its first (largest) rung — never
        // stepping down, and distinguishable from both the 8192
        // explicit-context figure and the 8192 no-fields-present fallback.
        #expect(manifest.profiles.first?.context == 32_768)
        #expect(manifest.profiles.first?.standard == profile.standard.chosen)

        _ = profile
    }
}
