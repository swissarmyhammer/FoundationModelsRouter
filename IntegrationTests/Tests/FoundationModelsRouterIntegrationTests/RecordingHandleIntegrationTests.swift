import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The same real `mlx-community` generation model this target's other gated
/// suites use for the `.standard` slot.
private let recordingHandleTinyModel: ModelRef = RealModels.standard

// MARK: - Suite

/// Gated real-model coverage for task 0n38p3w: the FIRST live traffic ever
/// exercised for the tool-aware recording schema (`Kind.toolCalls` /
/// `Kind.toolOutput` / `ToolDefinitionPayload`), proving a tool-using turn
/// driven directly over a ``RecordingLanguageModel`` handle (`RoutedModel/makeLanguageModel()`)
/// round-trips to disk: everything up through `.toolOutput` back-fills live,
/// during the turn (alongside an empty, metadata-only `.response` entry the
/// tool-calling round registers before it ever decides to call a tool — real,
/// verified executor behavior, not a recording bug), and the turn's real,
/// populated final answer only lands once the caller closes the
/// executor-boundary gap with `handle.sync(session.transcript)` at turn end —
/// exactly as a harness frontend is expected to.
///
/// Builds a real ``LanguageModelProfile`` directly over an already-loaded tiny
/// model's ``MLXFoundationModelsContainer`` through ``RealModelHarness`` — the
/// build every real-model suite of this target shares — bypassing
/// `Router.resolve(_:reporting:)`, which would need real `.flash`/`.embedding`
/// downloads too, since this suite only ever drives `.standard`.
///
/// This suite runs on a machine that holds the `recordingHandleTinyModel`
/// weights in its Hugging Face cache. The run of 2026-08-21, on an Apple
/// silicon Mac, under
/// `swift test --package-path IntegrationTests --filter RecordingHandleIntegrationTests`,
/// against the mlx-swift-lm fork at revision `41e9f41`
/// (`IntegrationTests/Package.resolved`), passed its one test in 21.4 seconds
/// of test wall clock, and 29.9 seconds for the whole command, build included.
/// That run confirmed each assertion below against a real session: the
/// on-disk event sequence, the mid-turn back-fill snapshot before `sync`, the
/// `session.json` sidecar fields, and the `MergedTranscript` and
/// `TranscriptTree` reconstruction, which matched the live transcript. A root
/// `swift test` leaves this suite out, because the root package cannot see
/// this package.
///
/// ## What it NO LONGER proves (task ^bpwfbyz)
///
/// Until that task the turn took the provider's default sampling, temperature
/// 0.6 out of MLX's clock-seeded, process-global PRNG, and no reply ceiling.
/// The three runs of 2026-08-20 measured this suite's one test at 16.7, then
/// 40.9, then 101.5 seconds, with no code change between the runs, and the run
/// of 2026-08-21 above measured it at 21.4 seconds. The 101.5 was six times
/// run 1 and 85 percent of ``integrationTestBudgetMinutes``. The 30B writes a
/// `<think>` block before each round of a tool turn, and under the sampler
/// that block, and the number of rounds, differed on every run. Two changes
/// bring the test inside half the budget, and ``turnOptions`` states both:
/// argmax decoding, and ``GatedRealModelBudget/responseTokenCeiling`` as each
/// round's reply ceiling. Measured in isolation on 2026-08-21 under those
/// options: 32.5 seconds, of which 3.4 seconds the load and 28.9 seconds the
/// turn, in two rounds.
///
/// What is no longer proven is:
///
/// - **The sampled path.** The turn decodes with argmax, so a red run is
///   attributable to the change under test, and the round trip under the
///   provider's default sampling is not measured here.
/// - **A round past the ceiling.** Each round of the tool turn stops at
///   ``GatedRealModelBudget/responseTokenCeiling`` tokens. A round that
///   generated past it, and what the recording shows of such a round, is no
///   longer measured here.
///
/// Everything else is untouched: the model, the handle, the tool, the prompt,
/// the instructions, and every assertion on the disk sequence, the sidecar and
/// the reconstruction are exactly what they were. See
/// ``integrationTestBudgetMinutes`` for the whole run table.
@Suite(
    "Gated real-model integration: a tool-using turn over a RecordingLanguageModel handle round-trips to disk (task 0n38p3w)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
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

    // MARK: - The turn's options

    /// The options the one turn below passes to `session.respond(to:options:)`.
    ///
    /// Two things are stated here, and deliberately here rather than on
    /// ``RealModelContainer/load(ref:context:samplingMode:)``. A sampling mode
    /// pinned at load time is read by the session backend a `RoutedSession`
    /// drives, and this suite drives no `RoutedSession`: it drives a raw
    /// `LanguageModelSession` over a ``RecordingLanguageModel`` handle, which
    /// wraps the container's language model directly and passes each request
    /// through untouched. The only options that reach the model on that path
    /// are the ones the turn passes.
    ///
    /// - Argmax decoding, for the reason ``SessionTreeRestorationIntegrationTests``
    ///   pins it: the provider default samples at temperature `0.6` from MLX's
    ///   process-global PRNG, which seeds itself from the clock, so the
    ///   `<think>` block before each round of this tool turn, and the number of
    ///   rounds, differed on every run of identical code. Argmax decoding
    ///   consumes no randomness at all.
    /// - ``GatedRealModelBudget/responseTokenCeiling`` as each round's reply
    ///   ceiling, the same ceiling every other gated turn of this target states,
    ///   where this turn stated none.
    private static let turnOptions = GenerationOptions(
        samplingMode: .greedy, maximumResponseTokens: GatedRealModelBudget.responseTokenCeiling)

    // MARK: - Harness

    private struct Harness {
        let profile: LanguageModelProfile
        let container: MLXFoundationModelsContainer
        let recordingsDir: URL
        let cacheDir: URL
    }

    /// Builds a real ``LanguageModelProfile`` directly over a freshly loaded
    /// tiny model, recording into a durable temp `recordingsDir` so its
    /// transcript can be reloaded through ``TranscriptTree``/``MergedTranscript``
    /// after the turn completes.
    ///
    /// The profile comes from ``RealModelHarness/make(model:context:container:cacheDir:recordingsDir:routerId:)``,
    /// the one real-profile build every real-model suite of this target uses.
    /// This suite's own hand-built copy said the same thing and was folded onto
    /// it (task ^zz6kam0): the same `JSONLRecorder` for the router and every
    /// handle, the same root-plus-writer ``DurableRecording`` pair `Router`
    /// builds — which is what `TranscriptTree.load` below reads — one gate set
    /// shared by the two generation handles, and one stub in the `.embedding`
    /// slot this suite never drives. The copy named its profile `"test"`; the
    /// harness stamps its own name, and nothing reads the field.
    private func makeHarness() async throws -> Harness {
        let container = try await RealModelContainer.load(ref: recordingHandleTinyModel)

        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RecordingHandleIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RecordingHandleIntegrationTests-cache-\(UUID().uuidString)", isDirectory: true)

        let profile = RealModelHarness.make(
            model: recordingHandleTinyModel,
            // The window the hand-built copy resolved at: it stated no
            // `contextTokens` at all, so every slot took `SlotResolution`'s own
            // default. Stated explicitly here, because the harness has no
            // default of its own to inherit.
            context: ProfileDefinition.defaultContext,
            container: container,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir
        )

        return Harness(
            profile: profile, container: container, recordingsDir: recordingsDir,
            cacheDir: cacheDir)
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
    /// its own `session.json` with the right slot/model, and reconstruction via
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

        let response = try await session.respond(
            to: "Call the echo tool with the text 'ping'.", options: Self.turnOptions)
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
        // A tool-calling round's executor invocation unconditionally sends a
        // metadata-only `.response` channel event (`updateMetadata`, no text)
        // before it ever decides to call a tool — confirmed empirically
        // against a real model: every `.response`-kind event recorded before
        // `sync` has `text == nil`. The turn's real, populated final answer
        // is still invisible at the executor boundary until `sync` closes
        // the gap below.
        #expect(beforeSync.filter { $0.kind == .response }.allSatisfy { $0.text == nil })

        // sync(session.transcript) at turn end closes that one gap.
        await handle.sync(session.transcript)

        let afterSync = try Self.recordedEvents(in: recordingDirectory)
        #expect(
            Self.isInOrderSubsequence(
                [.session, .instructions, .prompt, .toolCalls, .toolOutput, .response],
                of: afterSync.map(\.kind)
            )
        )
        // The turn's final answer is now on disk, and nothing of the turn
        // stands after it except the model's own reasoning: the gated model
        // writes a `<think>` block, which the SDK appends as a `.reasoning`
        // entry after the `.response` (see `GatedRealModelBudget`). So this
        // reads "the last entry that is not reasoning is the response". A
        // missing final answer — the one gap `sync` exists to close — leaves
        // `.toolOutput` there instead and still fails, and a `.prompt` or a
        // `.toolCalls` after the answer fails it too.
        let afterSyncKinds = afterSync.map(\.kind)
        #expect(
            afterSyncKinds.last(where: { $0 != .reasoning }) == .response,
            "the turn should end with its final response; kinds were \(afterSyncKinds)"
        )

        // The handle's own directory carries its sidecar, with the right
        // slot/model.
        let routerDirectory = harness.recordingsDir
            .appendingPathComponent(harness.profile.standard.routerId.description, isDirectory: true)
        let ownSidecar = try #require(try SessionSidecar.read(in: recordingDirectory))
        #expect(ownSidecar.slot == .standard)
        #expect(ownSidecar.model == recordingHandleTinyModel)

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

        await harness.container.model.evict()
    }
}
