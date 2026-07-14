import Foundation
import FoundationModels
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Testing
import Tokenizers

@testable import FoundationModelsRouter

// MARK: - Gate

/// Reuses the same opt-in gating pattern as the rest of this target: unset
/// (the default, and on any CI/GPU-less box) this whole suite is skipped, so
/// `swift test` stays green without network or a GPU. Kept as its own
/// file-scoped constant rather than sharing another file's — Swift's
/// top-level `private` is file-scoped, not target-scoped.
private let recordingHandleIntegrationEnvVar = "FM_ROUTER_INTEGRATION_TESTS"

private var recordingHandleIntegrationEnabled: Bool {
    ProcessInfo.processInfo.environment[recordingHandleIntegrationEnvVar] != nil
}

/// The same deliberately tiny `mlx-community` generation model this target's
/// other gated suites use.
private let recordingHandleTinyModel: ModelRef = "mlx-community/SmolLM-135M-Instruct-4bit"

// MARK: - Suite

/// Gated real-model coverage for task 0n38p3w: the FIRST live traffic ever
/// exercised for the tool-aware recording schema (`Kind.toolCalls` /
/// `Kind.toolOutput` / `ToolDefinitionPayload`), proving a tool-using turn
/// driven directly over a ``RecordingLanguageModel`` handle (`RoutedLLM/makeLanguageModel()`)
/// round-trips to disk: everything up through `.toolOutput` back-fills live,
/// during the turn, and the turn-final `.response` only lands once the caller
/// closes the executor-boundary gap with `handle.sync(session.transcript)` at
/// turn end — exactly as a harness frontend is expected to.
///
/// Builds a real ``LanguageModelProfile`` directly over an already-loaded tiny
/// model's ``MLXFoundationModelsContainer`` — the same technique
/// ``LanguageModelSessionBackendIntegrationTests`` and
/// ``TranscriptReconstructionIntegrationTests`` use — bypassing
/// `Router.resolve(_:reporting:)`, which would need real `.flash`/`.embedding`
/// downloads too, since this suite only ever drives `.standard`.
///
/// IMPORTANT — this suite could not be executed live in this sandbox: there
/// is no GPU/Apple Silicon and no network access here to download
/// `recordingHandleTinyModel`, so `FM_ROUTER_INTEGRATION_TESTS=1` was never
/// actually set against a real run. Everything below is verified to *compile*
/// and to *skip* (not run) under a normal `swift test` invocation without the
/// env var. To finish verifying the acceptance criteria that need an actual
/// live run — the exact on-disk event sequence, the mid-turn back-fill
/// snapshot before `sync`, the `sessions.jsonl` fields, and the
/// `MergedTranscript`/`TranscriptTree` reconstruction all matching a real
/// session's live transcript — someone needs to run this suite on a real
/// Apple Silicon Mac with network access to the Hub (so the tiny model can be
/// downloaded/cached) and `FM_ROUTER_INTEGRATION_TESTS=1` set, then confirm
/// the assertions below hold and report back.
@Suite(
    "Gated real-model integration: a tool-using turn over a RecordingLanguageModel handle round-trips to disk (task 0n38p3w)",
    .serialized,
    .timeLimit(.minutes(15)),
    .enabled(if: recordingHandleIntegrationEnabled)
)
struct RecordingHandleIntegrationTests {
    // MARK: - Test tool

    /// The scripted tool argument schema the turn's prompt reliably drives:
    /// a single required string field, the smallest surface a tiny model can
    /// reliably fill in when directly instructed to call this tool with the
    /// user's exact text.
    @Generable
    struct EchoArguments {
        let text: String
    }

    /// A real `FoundationModels.Tool` conformer — mirrors ``EchoTool`` in
    /// `Tests/FoundationModelsRouterTests/RecordingLanguageModelTests.swift`
    /// — so the SDK's own machinery invokes it once it observes a `.toolCalls`
    /// entry naming it and folds the result back in as `.toolOutput`.
    private struct EchoTool: FoundationModels.Tool {
        let name = "echo"
        let description = "Echoes the given text back verbatim."

        func call(arguments: EchoArguments) async throws -> String {
            "echoed: \(arguments.text)"
        }
    }

    /// A minimal ``LoadedEmbeddingContainer`` stand-in for the unused
    /// `.embedding` slot the ``LanguageModelProfile`` this suite builds must
    /// still carry — never exercised here, only present to satisfy the type.
    private struct UnusedEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension = 1
        func embed(texts: [String]) async throws -> [[Float]] { [] }
    }

    // MARK: - Harness

    private struct Harness {
        let profile: LanguageModelProfile
        let router: Router
        let recordingsDir: URL
        let cacheDir: URL
    }

    /// Loads the tiny model directly through a real ``LiveModelLoader`` and
    /// returns its concrete ``MLXFoundationModelsContainer``.
    private func makeContainer() async throws -> MLXFoundationModelsContainer {
        let loader = LiveModelLoader(
            downloader: #hubDownloader(),
            tokenizerLoader: #huggingFaceTokenizerLoader()
        )
        let loaded = try await loader.loadLLM(
            ref: recordingHandleTinyModel,
            slot: .standard,
            context: 512,
            reporting: { _ in }
        )
        return try #require(loaded as? MLXFoundationModelsContainer)
    }

    /// Builds a real ``LanguageModelProfile`` directly over a freshly loaded
    /// tiny model, recording into a durable temp `recordingsDir` so its
    /// transcript can be reloaded through ``TranscriptTree``/``MergedTranscript``
    /// after the turn completes — the same manual-harness technique this
    /// target's other gated suites use.
    private func makeHarness() async throws -> Harness {
        let container = try await makeContainer()

        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingHandleIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingHandleIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)

        let recorder = JSONLRecorder(directory: recordingsDir)
        let router = Router(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)
        // Actor-isolated on Router; awaited once here and threaded into every
        // RoutedModel below so the handle's SessionIndexRecord actually lands
        // in sessions.jsonl (RoutedModel's own `sessionIndexWriter` defaults
        // to nil unless explicitly passed).
        let sessionIndexWriter = await router.sessionIndexWriter

        func noopResolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(slot: slot, remainingBudgetBytes: 0, chosen: recordingHandleTinyModel, considered: [])
        }
        let standard = RoutedLLM(
            slot: .standard,
            chosen: recordingHandleTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.standard),
            container: container,
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir,
            sessionIndexWriter: sessionIndexWriter
        )
        let flash = RoutedLLM(
            slot: .flash,
            chosen: recordingHandleTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.flash),
            container: container,
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir,
            sessionIndexWriter: sessionIndexWriter
        )
        let embedding = RoutedEmbedder(
            slot: .embedding,
            chosen: recordingHandleTinyModel,
            footprintBytes: 0,
            resolution: noopResolution(.embedding),
            container: UnusedEmbeddingContainer(),
            routerId: router.id,
            recorder: recorder,
            recordingsRoot: recordingsDir,
            sessionIndexWriter: sessionIndexWriter
        )
        let profile = LanguageModelProfile(
            definitionName: "test",
            standard: standard,
            flash: flash,
            embedding: embedding,
            router: router,
            residencyToken: .generate()
        )

        return Harness(profile: profile, router: router, recordingsDir: recordingsDir, cacheDir: cacheDir)
    }

    /// Decodes every newline-delimited JSON record of type `T` from
    /// `fileName` inside `directory`. When `checkExists` is `true`, a missing
    /// file yields `[]` instead of throwing — used by callers where the file
    /// not existing yet is itself the thing under test (a meaningful
    /// assertion failure), not a harness error.
    private static func readJSONLFile<T: Decodable>(
        in directory: URL,
        fileName: String,
        checkExists: Bool = false
    ) throws -> [T] {
        let fileURL = directory.appendingPathComponent(fileName, isDirectory: false)
        if checkExists, !FileManager.default.fileExists(atPath: fileURL.path) {
            return []
        }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(separator: "\n").filter { !$0.isEmpty }.map {
            try decoder.decode(T.self, from: Data($0.utf8))
        }
    }

    /// Decodes every event from a session directory's `transcript.jsonl`, or
    /// an empty array if the file does not exist yet.
    private static func recordedEvents(in directory: URL) throws -> [TranscriptEvent] {
        try readJSONLFile(in: directory, fileName: "transcript.jsonl", checkExists: true)
    }

    /// Decodes every record from a router directory's `sessions.jsonl`, or an
    /// empty array if the file does not exist yet (so a missing file surfaces
    /// as a meaningful assertion failure rather than a file-not-found error).
    private static func sessionIndexRecords(underRouterDirectory routerDirectory: URL) throws -> [SessionIndexRecord] {
        try readJSONLFile(in: routerDirectory, fileName: "sessions.jsonl", checkExists: true)
    }

    /// Whether `expected` appears as an in-order (not necessarily contiguous)
    /// subsequence of `actual` — the acceptance criterion's "contains, in
    /// order" phrasing, checked structurally rather than by exact equality so
    /// a real model's occasional extra interleaved entry (e.g. a `.reasoning`
    /// entry, or more than one tool-calling round before it settles) does not
    /// make an otherwise-correct recording fail this check.
    private static func isInOrderSubsequence<T: Equatable>(_ expected: [T], of actual: [T]) -> Bool {
        var searchStart = actual.startIndex
        for want in expected {
            guard let found = actual[searchStart...].firstIndex(of: want) else { return false }
            searchStart = actual.index(after: found)
        }
        return true
    }

    /// Task 0n38p3w's core acceptance criteria, proved against a real model:
    /// a tool-using turn driven directly over a ``RecordingLanguageModel``
    /// handle back-fills `.session`/`.instructions`/`.prompt`/`.toolCalls`/
    /// `.toolOutput` to disk live (before any `sync`), the turn-final
    /// `.response` only lands once `sync(session.transcript)` closes the
    /// executor-boundary gap at turn end, the handle's own session appears in
    /// `sessions.jsonl` with the right slot/model, and reconstruction via
    /// ``TranscriptTree``/``MergedTranscript`` over the recorded directory
    /// matches the live session's own transcript kind-for-kind.
    @Test("a tool-using turn over a RecordingLanguageModel handle round-trips to disk: mid-turn back-fill before sync, final response only after sync(session.transcript)")
    func toolUsingTurnRoundTripsToDisk() async throws {
        let harness = try await makeHarness()
        defer {
            try? FileManager.default.removeItem(at: harness.recordingsDir)
            try? FileManager.default.removeItem(at: harness.cacheDir)
        }

        let handle = harness.profile.standard.makeLanguageModel()
        let session = LanguageModelSession(
            model: handle,
            tools: [EchoTool()],
            instructions: """
                You always respond to the user by calling the `echo` tool with the \
                user's exact text as its `text` argument, then report the tool's result \
                back to the user.
                """
        )

        let response = try await session.respond(to: "Call the echo tool with the text 'ping'.")
        #expect(!response.content.isEmpty)

        // Before sync: the diff-on-generate chokepoint has already back-filled
        // everything up through .toolOutput to disk, live, during the turn —
        // the turn-final .response is the one thing the executor boundary
        // cannot see.
        let recordingDirectory = handle.state.recordingDirectory
        let beforeSync = try Self.recordedEvents(in: recordingDirectory)
        #expect(
            Self.isInOrderSubsequence(
                [.session, .instructions, .prompt, .toolCalls, .toolOutput],
                of: beforeSync.map(\.kind)
            )
        )
        #expect(!beforeSync.map(\.kind).contains(.response))

        // sync(session.transcript) at turn end closes that one gap.
        await handle.sync(session.transcript)

        let afterSync = try Self.recordedEvents(in: recordingDirectory)
        #expect(
            Self.isInOrderSubsequence(
                [.session, .instructions, .prompt, .toolCalls, .toolOutput, .response],
                of: afterSync.map(\.kind)
            )
        )
        #expect(afterSync.map(\.kind).last == .response)

        // The handle's own session appears in sessions.jsonl with the right
        // slot/model.
        let routerDirectory = harness.recordingsDir
            .appendingPathComponent(harness.router.id.description, isDirectory: true)
        let indexRecords = try Self.sessionIndexRecords(underRouterDirectory: routerDirectory)
        let ownRecord = try #require(indexRecords.first { $0.sessionId == handle.state.sessionId })
        #expect(ownRecord.slot == .standard)
        #expect(ownRecord.model == recordingHandleTinyModel)

        // Reconstruction over the recorded directory matches the live
        // session's own transcript, kind-for-kind.
        let tree = try TranscriptTree.load(under: routerDirectory)
        let reconstructed = try tree.effectiveTranscript(forSession: handle.state.sessionId)
        let reconstructedKinds = reconstructed.map { TranscriptEntryMapper.event(from: $0).kind }
        let liveKinds = session.transcript.map { TranscriptEntryMapper.event(from: $0).kind }
        #expect(reconstructedKinds == liveKinds)
        #expect(!reconstructedKinds.isEmpty)

        let merged = try MergedTranscript.merged(under: routerDirectory)
        #expect(merged.map(\.kind) == afterSync.map(\.kind))
    }
}
