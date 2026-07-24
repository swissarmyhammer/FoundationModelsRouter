import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ffsjqha (compaction epic — compaction_plan.md §1.4,
/// build-order step 6): ``RoutedSession/compact(prompt:budget:)``, the
/// session-level entry point that folds a ``RoutedSessionActor``'s live
/// transcript in place — the actor counterpart to
/// ``RecordingLanguageModel/noteCompaction(_:)`` for a bare session over the
/// recording handle. Both are implemented on the same bare primitives
/// (``Compactor/compact(_:prompt:budget:summarizer:)`` +
/// ``LanguageModelSessionBackend/replacingTranscript(_:)``) — one mechanism,
/// two entry points (compaction_plan.md §7).
///
/// Everything runs against a stub ``LoadedLLMContainer``/``StubSessionBackend``
/// and an ``InMemoryRecorder``, so the suite needs no network and no GPU.
/// Budgets are derived from the real, measured pre-fold byte-size estimate
/// (via ``Compactor/estimatedTokenCount(of:)``, accessible through
/// `@testable import`) rather than hand-picked magic numbers, so the tests
/// stay meaningful regardless of exactly how the mapper serializes an entry.
@Suite("RoutedSession.compact(prompt:budget:): in-place fold on the actor")
struct RoutedSessionCompactTests {
    // MARK: - Stub container

    /// Vends a single, test-retained ``StubSessionBackend`` per session, so a
    /// test can inspect its accumulated entries and derive an exact budget
    /// forcing (or not forcing) a fold.
    private final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let responseText: String
        let usageIncrement: (input: Int, output: Int)?
        private(set) var lastBackend: StubSessionBackend?

        init(responseText: String, usageIncrement: (input: Int, output: Int)? = nil) {
            self.responseText = responseText
            self.usageIncrement = usageIncrement
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(
                responseText: responseText, instructions: instructions, usageIncrement: usageIncrement)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText, entries: Array(transcript), usageIncrement: usageIncrement)
        }
    }

    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    private struct StubModelLoader: ModelLoader {
        let container: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return container
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

    // MARK: - Fixture content

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

    private static let stubDimension = 8

    /// A long-ish canned response, repeated across every turn, so a handful
    /// of turns' worth of transcript already carries a real, non-trivial
    /// byte-size estimate — the recency window alone (the newest 4 turns
    /// ``ToolOutputElision``/``TurnTruncation`` never touch) is large enough
    /// that a tight-enough budget still needs the model-assisted
    /// ``Summarization`` stage to land under target.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    private static func profile(context: Int) -> ProfileDefinition {
        ProfileDefinition(
            name: "coding",
            description: "test profile",
            standard: ["org/std-a"],
            flash: ["org/flash-a"],
            embedding: ["org/emb-a"],
            context: context
        )
    }

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoutedSessionCompactTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(
        container: ConfiguredLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL
    ) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
    }

    /// Drives `count` sequential `respond(to:)` turns on `session`.
    private static func driveTurns(_ count: Int, on session: RoutedSession) async throws {
        for index in 0..<count {
            _ = try await session.respond(to: "turn \(index)")
        }
    }

    /// The estimated token size of just `entries`' un-foldable recency
    /// window (the header plus the newest 4 turns) — the floor no
    /// deterministic stage can fold below, so a `budget.target` under this
    /// forces the model-assisted ``Summarization`` stage to run.
    private static func recencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
        let (header, turns) = TranscriptTurns.split(entries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
    }

    // MARK: - Shrinks the live window; accurate result

    @Test("compact() shrinks the live window (post-compact contextFill < pre-compact) and returns an accurate CompactionResult")
    @MainActor
    func compactShrinksLiveWindowAndReportsAccurateResult() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        // A large per-turn usage delta relative to the tiny stub transcript's
        // own byte-size estimate — simulating a session whose measured fill
        // is already high (why compaction would run), on a fixed scale that
        // stays comparable across the two turns driven below.
        let container = ConfiguredLLMContainer(responseText: Self.cannedText, usageIncrement: (input: 50_000, output: 0))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // More than the default keepRecentTurns (4): with only 4 or fewer
        // turns every turn is inside the untouchable recency window, so
        // neither ToolOutputElision/TurnTruncation nor Summarization has
        // anything to fold — this drives enough turns that older ones fall
        // outside it.
        try await Self.driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preFoldTokens = Compactor.estimatedTokenCount(of: Transcript(entries: backend.transcriptEntries()))
        let recencyOnly = Self.recencyWindowOnlyEstimate(backend.transcriptEntries())
        let preFoldFill = await session.contextFill
        // A turn's own usage delta reports the *whole* transcript's size at
        // that point (generation is stateless) — not a cumulative sum across
        // turns — so with a constant 50,000-token delta per turn against a
        // 100,000-token context, fill sits at 0.5 regardless of turn count.
        #expect(preFoldFill == 0.5)

        // A budget whose target sits strictly between the recency-window-only
        // floor and the full pre-fold estimate: low enough to guarantee the
        // pipeline actually folds something, high enough that the
        // deterministic TurnTruncation stage alone lands under it — a clean
        // shrink that never needs (and isn't skewed by) the model-assisted
        // Summarization stage's own synthesized-entry overhead.
        let targetTokens = (recencyOnly + preFoldTokens) / 2
        let budget = TokenBudget(limit: preFoldTokens, target: Double(targetTokens) / Double(preFoldTokens))
        let result = try await session.compact(budget: budget)

        #expect(!result.stagesApplied.isEmpty)
        #expect(result.tokensBefore == preFoldTokens)
        #expect(result.tokensAfter < result.tokensBefore)

        let postFoldFill = await session.contextFill
        #expect(postFoldFill < preFoldFill)
        // The post-fold fill reflects this fold's own accurate tokensAfter
        // over the resolved 100,000-token context.
        #expect(postFoldFill == Double(result.tokensAfter) / 100_000)
    }

    // MARK: - Identity + append-only recording

    @Test("compact() preserves session id and recordingDirectory; prior recorded events are untouched and the fold's summary entry is appended")
    @MainActor
    func compactIsAppendOnlyAndPreservesIdentity() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.driveTurns(6, on: session)

        let sessionId = session.id
        let recordingDirectory = session.recordingDirectory

        let backend = try #require(container.lastBackend)
        let recencyOnly = Self.recencyWindowOnlyEstimate(backend.transcriptEntries())
        // A target strictly under the recency window's own floor: neither
        // ToolOutputElision nor TurnTruncation can land under this alone, so
        // the model-assisted Summarization stage must run and synthesize a
        // summary entry.
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)

        let beforeEvents = await recorder.events
        #expect(!beforeEvents.isEmpty)

        let result = try await session.compact(budget: budget)
        #expect(result.summary != nil)
        #expect(result.stagesApplied.contains("Summarization"))

        // Identity: requirement 4.
        #expect(session.id == sessionId)
        #expect(session.recordingDirectory == recordingDirectory)

        // Append-only: requirement 2 — nothing before the fold is touched.
        let afterEvents = await recorder.events
        #expect(afterEvents.count > beforeEvents.count)
        #expect(Array(afterEvents.prefix(beforeEvents.count)) == beforeEvents)

        // The appended entry carries a CompactionSegment.
        let appended = try #require(afterEvents.last)
        #expect(appended.kind == .response)
        #expect(appended.sessionId == sessionId)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind, registry: .routerDefault)
        guard case .response(let response) = rebuilt, case .custom(let segment)? = response.segments.last,
            let compactionSegment = segment as? CompactionSegment
        else {
            Issue.record("expected the appended entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compactionSegment.content.stagesApplied.contains("Summarization"))
        #expect(!compactionSegment.content.foldedEntryIds.isEmpty)
    }

    // MARK: - Post-compact turns work normally

    @Test("respond() works normally after compaction; a follow-up turn records as a normal append")
    @MainActor
    func respondWorksNormallyAfterCompaction() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preFoldTokens = Compactor.estimatedTokenCount(of: Transcript(entries: backend.transcriptEntries()))
        let budget = TokenBudget(limit: preFoldTokens * 2, target: 0.25)
        try await session.compact(budget: budget)

        let beforeTurnEvents = await recorder.events

        let response = try await session.respond(to: "one more turn")
        #expect(response == Self.cannedText)

        let afterTurnEvents = await recorder.events
        #expect(Array(afterTurnEvents.prefix(beforeTurnEvents.count)) == beforeTurnEvents)
        let newEvents = Array(afterTurnEvents.suffix(from: beforeTurnEvents.count))
        #expect(newEvents.map(\.kind) == [.prompt, .response])
        #expect(newEvents.allSatisfy { $0.sessionId == session.id })
    }

    // MARK: - Defaults resolve when omitted

    @Test("compact() with no arguments resolves prompt to CompactionPrompt.default and budget to this session's own resolved working context")
    @MainActor
    func defaultPromptAndBudgetResolveWhenOmitted() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)

        // Drive turns first (against a throwaway large-context profile) so
        // the real recency-window-only estimate is known before picking a
        // context tight enough that the *default* budget (target 0.5 of
        // this profile's own context) still needs Summarization.
        let scratchProfile = try await router.resolve(
            profile: Self.profile(context: 1_000_000), reporting: ResolutionProgress())
        let scratchSession = scratchProfile.standard.makeSession()
        try await Self.driveTurns(6, on: scratchSession)
        let scratchBackend = try #require(container.lastBackend)
        let recencyOnly = Self.recencyWindowOnlyEstimate(scratchBackend.transcriptEntries())

        // A fresh router/profile whose resolved context makes the *default*
        // budget's 0.5 target land strictly below the recency-window floor.
        let recorder2 = InMemoryRecorder()
        let container2 = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router2 = Self.makeRouter(container: container2, recorder: recorder2, cacheDir: Self.makeTempDir())
        let tightContext = recencyOnly
        let profile2 = try await router2.resolve(
            profile: Self.profile(context: tightContext), reporting: ResolutionProgress())
        let session2 = profile2.standard.makeSession()
        try await Self.driveTurns(6, on: session2)

        let result = try await session2.compact()

        #expect(result.stagesApplied.contains("Summarization"))
        #expect(result.summary != nil)

        // The default prompt's name is what gets recorded in the fold's
        // CompactionSegment.
        let events = await recorder2.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind, registry: .routerDefault)
        guard case .response(let response) = rebuilt, case .custom(let segment)? = response.segments.last,
            let compactionSegment = segment as? CompactionSegment
        else {
            Issue.record("expected the appended entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compactionSegment.content.promptName == CompactionPrompt.default.name)
    }

    // MARK: - Custom prompt threads through

    @Test("compact(prompt:) threads a custom CompactionPrompt's name into the recorded CompactionSegment")
    @MainActor
    func customPromptNameIsRecordedInCompactionSegment() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let recencyOnly = Self.recencyWindowOnlyEstimate(backend.transcriptEntries())
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)
        let customPrompt = CompactionPrompt(name: "custom-test-prompt-v1", text: "Summarize tersely.")

        let result = try await session.compact(prompt: customPrompt, budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let events = await recorder.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind, registry: .routerDefault)
        guard case .response(let response) = rebuilt, case .custom(let segment)? = response.segments.last,
            let compactionSegment = segment as? CompactionSegment
        else {
            Issue.record("expected the appended entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compactionSegment.content.promptName == "custom-test-prompt-v1")
    }

    // MARK: - Throwing summarizer leaves the session untouched

    @Test("when the model-assisted summarizer throws, compact() leaves session id, recordingDirectory, contextFill, and recorded events untouched, and a later respond() still works normally")
    @MainActor
    func compactLeavesSessionUntouchedWhenSummarizerThrows() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        // A configured usageIncrement so contextFill is a concrete measured
        // number (not the `unknownContextFill` NaN sentinel a backend
        // reporting no usage at all would leave it at) — comparing two NaN
        // values for equality is always false, which would make this test's
        // own "fill unchanged" assertion meaningless.
        let container = ConfiguredLLMContainer(responseText: Self.cannedText, usageIncrement: (input: 123, output: 45))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.driveTurns(6, on: session)

        let sessionId = session.id
        let recordingDirectory = session.recordingDirectory
        let backend = try #require(container.lastBackend)
        let recencyOnly = Self.recencyWindowOnlyEstimate(backend.transcriptEntries())
        // Strictly under the recency-window floor: forces the model-assisted
        // Summarization stage to run (see compactIsAppendOnlyAndPreservesIdentity).
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)

        let beforeEvents = await recorder.events
        let beforeFill = await session.contextFill

        // `BackendCompactionSummarizer` builds its blank-slate backend via
        // `replacingTranscript(_:)`, which (per `StubSessionBackend`'s own
        // implementation) propagates `shouldThrow` from the backend it is
        // built from — so flipping it here on the session's live backend
        // makes every summarizer call fail.
        backend.shouldThrow = true

        await #expect(throws: StubSessionBackend.StubError.self) {
            try await session.compact(budget: budget)
        }

        // Nothing changed: identity, fill, and the recorded transcript are
        // exactly as they were before the failed fold attempt.
        #expect(session.id == sessionId)
        #expect(session.recordingDirectory == recordingDirectory)
        let afterFill = await session.contextFill
        #expect(afterFill == beforeFill)
        let afterEvents = await recorder.events
        #expect(afterEvents == beforeEvents)

        // A subsequent turn still works normally — the session's backend was
        // never swapped for the (failed) fold attempt's summarizer backend.
        backend.shouldThrow = false
        let response = try await session.respond(to: "still fine")
        #expect(response == Self.cannedText)
    }

    // MARK: - No-op when already under budget

    @Test("compact() with an already-under-target transcript returns an unchanged result and leaves the session untouched")
    @MainActor
    func compactWithNothingToFoldReturnsUnchanged() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await Self.driveTurns(2, on: session)

        // A generous budget the tiny two-turn transcript is already well
        // under.
        let budget = TokenBudget(limit: 1_000_000, target: 0.9)
        let beforeEvents = await recorder.events

        let result = try await session.compact(budget: budget)

        #expect(result.stagesApplied.isEmpty)
        #expect(result.summary == nil)
        #expect(result.tokensAfter == result.tokensBefore)

        let afterEvents = await recorder.events
        #expect(afterEvents == beforeEvents)

        // A follow-up turn still works normally.
        let response = try await session.respond(to: "still working")
        #expect(response == Self.cannedText)
    }
}
