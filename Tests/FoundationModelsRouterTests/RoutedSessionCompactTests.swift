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
/// (``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)`` +
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

        /// The shared log every backend this container vends records into —
        /// including the blank-slate clone a fold's summarizer builds through
        /// `replacingTranscript(_:)`, which is the only place a fold's own
        /// calls are observable from outside the session.
        let generationLog = StubGenerationLog()

        private(set) var lastBackend: StubSessionBackend?

        init(responseText: String, usageIncrement: (input: Int, output: Int)? = nil) {
            self.responseText = responseText
            self.usageIncrement = usageIncrement
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(
                responseText: responseText, instructions: instructions, usageIncrement: usageIncrement,
                generationLog: generationLog)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(
                responseText: responseText, entries: Array(transcript), usageIncrement: usageIncrement,
                generationLog: generationLog)
            lastBackend = backend
            return backend
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
        id: ULID = .generate(),
        container: ConfiguredLLMContainer,
        recorder: any TranscriptRecorder,
        cacheDir: URL,
        recordingsDir: URL? = nil
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
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
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preFoldTokens = Compactor.estimatedTokenCount(of: Transcript(entries: backend.transcriptEntries()))
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
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
        // The post-fold fill reflects this fold's own shrink ratio applied to
        // the measured usage the session already had — `tokensAfter` is the
        // pipeline's character-ratio estimate, and `contextFill`'s numerator
        // is measured tokens, so the estimate is rescaled onto that scale
        // before it is reported (see `RoutedSessionActor.foldedUsage`).
        let expectedPostFoldTokens = (50_000.0 * Double(result.tokensAfter) / Double(preFoldTokens)).rounded()
        #expect(postFoldFill == expectedPostFoldTokens / 100_000)
    }

    // MARK: - A fold's reported fill is measured, not estimated

    @Test("a fold never raises contextFill, even when the pipeline's own estimate of the folded transcript exceeds the session's measured usage")
    @MainActor
    func foldReportsShrinkOnTheMeasuredScale() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        // A *small* per-turn measured usage against a transcript the
        // character-ratio estimator sizes far higher — the arrangement that
        // exposed the unit mismatch on real hardware, where an over-counting
        // estimate written into `contextFill`'s numerator made a genuine fold
        // report a *higher* fill than the measured one it replaced (0.95068
        // after a fold from 0.89453). The fold's own accounting has to be
        // denominated in the same tokens the pre-fold fill was, or a caller
        // comparing the two compares incommensurable numbers.
        let measuredTokensPerTurn = 200
        let container = ConfiguredLLMContainer(
            responseText: Self.cannedText, usageIncrement: (input: measuredTokensPerTurn, output: 0))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preFoldTokens = Compactor.estimatedTokenCount(of: Transcript(entries: backend.transcriptEntries()))
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
        let preFoldFill = await session.contextFill
        // The premise of this test: even the part of the transcript no
        // deterministic stage may touch estimates larger than everything the
        // session has actually measured, so reporting the fold's own estimate
        // raw could only raise fill.
        #expect(recencyOnly > measuredTokensPerTurn)

        // The same deterministic-shrink budget
        // `compactShrinksLiveWindowAndReportsAccurateResult` uses — a target
        // TurnTruncation alone lands under, so what this test measures is the
        // unit the shrink is reported in and nothing else.
        let targetTokens = (recencyOnly + preFoldTokens) / 2
        let budget = TokenBudget(limit: preFoldTokens, target: Double(targetTokens) / Double(preFoldTokens))
        let result = try await session.compact(budget: budget)
        #expect(result.tokensAfter < result.tokensBefore)

        let postFoldFill = await session.contextFill
        #expect(postFoldFill < preFoldFill)
        let expectedPostFoldTokens =
            (Double(measuredTokensPerTurn) * Double(result.tokensAfter) / Double(preFoldTokens)).rounded()
        #expect(postFoldFill == expectedPostFoldTokens / 100_000)
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
        try await driveTurns(6, on: session)

        let sessionId = session.id
        let recordingDirectory = session.recordingDirectory

        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
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
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .response(let response) = rebuilt, case .structure(let segment)? = response.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
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
        try await driveTurns(6, on: session)

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
        try await driveTurns(6, on: scratchSession)
        let scratchBackend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(scratchBackend.transcriptEntries())

        // A fresh router/profile whose resolved context makes the *default*
        // budget's 0.5 target land strictly below the recency-window floor.
        let recorder2 = InMemoryRecorder()
        let container2 = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router2 = Self.makeRouter(container: container2, recorder: recorder2, cacheDir: Self.makeTempDir())
        let tightContext = recencyOnly
        let profile2 = try await router2.resolve(
            profile: Self.profile(context: tightContext), reporting: ResolutionProgress())
        let session2 = profile2.standard.makeSession()
        try await driveTurns(6, on: session2)

        let result = try await session2.compact()

        #expect(result.stagesApplied.contains("Summarization"))
        #expect(result.summary != nil)

        // The default prompt's name is what gets recorded in the fold's
        // CompactionSegment.
        let events = await recorder2.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .response(let response) = rebuilt, case .structure(let segment)? = response.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
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
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)
        let customPrompt = CompactionPrompt(name: "custom-test-prompt-v1", text: "Summarize tersely.")

        let result = try await session.compact(prompt: customPrompt, budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let events = await recorder.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .response(let response) = rebuilt, case .structure(let segment)? = response.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
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
        try await driveTurns(6, on: session)

        let sessionId = session.id
        let recordingDirectory = session.recordingDirectory
        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
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
        try await driveTurns(2, on: session)

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

    // MARK: - Live completionTokens cross the compaction boundary (task ^6e7h2q6)

    /// The last recorded event's rebuilt boundary `.response` — the entry
    /// every applied fold appends, carrying its ``CompactionSegment``
    /// checkpoint — or records an issue.
    private static func lastRecordedBoundary(
        in recorder: InMemoryRecorder
    ) async throws -> (response: Transcript.Response, segment: CompactionSegment) {
        let events = await recorder.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .response(let response) = rebuilt, case .structure(let segment)? = response.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
            throw StubSessionBackend.StubError.boom
        }
        return (response, compactionSegment)
    }

    /// The contents of every `.text` segment in `response`, in order.
    private static func textContents(of response: Transcript.Response) -> [String] {
        response.segments.compactMap { segment -> String? in
            guard case .text(let text) = segment else { return nil }
            return text.content
        }
    }

    @Test(
        "compact() with a parked run records its completionToken, op, and latest progress in the boundary CompactionSegment and renders them into a model-visible text segment"
    )
    @MainActor
    func compactCarriesParkedRunAcrossBoundary() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let latch = RunLatch()
        let token = await parkFakeRun(on: session.mailbox, latch: latch)
        await session.mailbox.updateProgress(completionToken: token, detail: "halfway through")

        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
        // Strictly under the recency-window floor: forces the model-assisted
        // Summarization stage — the only stage that synthesizes a boundary
        // entry — to run (see compactIsAppendOnlyAndPreservesIdentity).
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)

        let result = try await session.compact(budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let (response, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)

        // Run plane only — token, op, latest progress — recorded in the
        // boundary segment at the moment the boundary was written.
        #expect(
            compactionSegment.content.pendingRuns == [
                CompactionSegment.PendingRunSummary(
                    completionToken: token,
                    op: FakeRun.op,
                    latestProgressDetail: "halfway through"
                )
            ])

        // The rendered boundary the post-compaction model reads: the summary
        // text plus one additional text segment carrying the pending-run
        // summary, so the model knows its tokens and can call status().
        let texts = Self.textContents(of: response)
        #expect(texts.count == 2)
        let rendering = try #require(texts.last)
        #expect(rendering.contains(token))
        #expect(rendering.contains(FakeRun.op))
        #expect(rendering.contains("halfway through"))
        #expect(rendering.contains("status()"))

        await latch.open()
    }

    @Test(
        "compact() with an empty mailbox adds nothing: pendingRuns stays nil and the boundary carries only the summary text and the CompactionSegment"
    )
    @MainActor
    func compactWithEmptyMailboxAddsNoPendingRunCarrier() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)

        let result = try await session.compact(budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let (response, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)

        #expect(compactionSegment.content.pendingRuns == nil)
        // Exactly the pre-existing boundary shape: one summary text segment
        // and the CompactionSegment — no pending-run carrier of any kind.
        #expect(Self.textContents(of: response).count == 1)
        #expect(response.segments.count == 2)
    }

    // MARK: - The session's own Summarization reaches its folds

    /// How many turns the two fold-tuning tests below drive before folding —
    /// more than ``Summarization``'s default `keepRecentTurns` of 4, so the
    /// default recency window and the narrowed one fold different spans.
    private static let turnsBeforeTunedFold = 6

    /// The recency window those tests vend their session's ``Summarization``
    /// with: half the stage's own default, so two turns the default window
    /// would have kept land in the span the summarizer actually reads.
    private static let narrowedRecentTurns = Summarization().keepRecentTurns / 2

    /// A canned response long enough that one turn's own rendered content
    /// exceeds ``Summarization``'s default ``Summarization/maxChunkTokens``.
    /// Every summarizer call a fold then makes is handed more than a full
    /// chunk, so its output ceiling is the stage's own cap — `maxChunkTokens`
    /// times ``Summarization/summaryTokenRatio`` — exactly, rather than a share
    /// of whatever happened to land in that chunk.
    private static let chunkOverflowingText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 280)

    /// Vends a session configured with `summarization` and drives
    /// ``turnsBeforeTunedFold`` turns on it, so it is ready to fold.
    ///
    /// - Parameters:
    ///   - responseText: The canned response every driven turn produces.
    ///   - summarization: The model-assisted stage to vend the session with.
    /// - Returns: The session, the container holding its shared generation log,
    ///   and the temp directory the caller is responsible for removing.
    private static func makeSessionReadyToFold(
        responseText: String,
        summarization: Summarization
    ) async throws -> (session: RoutedSession, container: ConfiguredLLMContainer, directory: URL) {
        let dir = Self.makeTempDir()
        let container = ConfiguredLLMContainer(responseText: responseText)
        let router = Self.makeRouter(container: container, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(summarization: summarization)
        try await driveTurns(Self.turnsBeforeTunedFold, on: session)
        return (session, container, dir)
    }

    /// Folds `session` against a budget derived from its own transcript that
    /// sits strictly under the recency-window floor — so no deterministic stage
    /// can land it and the model-assisted ``Summarization`` stage must run —
    /// and returns the calls that fold made, without the warm-up turns' own.
    ///
    /// - Parameters:
    ///   - session: The session to fold.
    ///   - container: The container holding the shared generation log the fold
    ///     records into.
    /// - Returns: The fold's own summarizer calls, in call order.
    private static func summarizerCallsOfForcedFold(
        _ session: RoutedSession,
        container: ConfiguredLLMContainer
    ) async throws -> [StubGenerationCall] {
        let backend = try #require(container.lastBackend)
        let recencyOnly = recencyWindowOnlyEstimate(backend.transcriptEntries())
        let budget = TokenBudget(limit: recencyOnly * 2, target: 0.25)
        let callsBeforeFold = container.generationLog.calls.count

        let result = try await session.compact(budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        return Array(container.generationLog.calls.suffix(from: callsBeforeFold))
    }

    @Test(
        "compact() folds with the Summarization the session was vended with: a narrowed keepRecentTurns puts turns the stage's default window keeps out into the span the summarizer reads"
    )
    @MainActor
    func compactFoldsWithTheSessionsOwnKeepRecentTurns() async throws {
        let narrowed = try await Self.makeSessionReadyToFold(
            responseText: Self.cannedText,
            summarization: Summarization(keepRecentTurns: Self.narrowedRecentTurns))
        defer { try? FileManager.default.removeItem(at: narrowed.directory) }
        let unturned = try await Self.makeSessionReadyToFold(
            responseText: Self.cannedText, summarization: Summarization())
        defer { try? FileManager.default.removeItem(at: unturned.directory) }

        let narrowedCalls = try await Self.summarizerCallsOfForcedFold(
            narrowed.session, container: narrowed.container)
        let unturnedCalls = try await Self.summarizerCallsOfForcedFold(
            unturned.session, container: unturned.container)

        // The newest turn only the narrowed window folds: inside the default
        // window, so a fold running at the stage's defaults never reads it.
        let narrowedWindowOnly = renderedLineOfNewestFoldedTurn(
            turnCount: Self.turnsBeforeTunedFold, keepRecentTurns: Self.narrowedRecentTurns)
        #expect(narrowedCalls.contains { $0.prompt.contains(narrowedWindowOnly) })
        #expect(!unturnedCalls.contains { $0.prompt.contains(narrowedWindowOnly) })

        // Both folds really did read a span — the newest turn the *default*
        // window folds is in each — so the assertions above separate two live
        // folds rather than a fold from a no-op.
        let foldedEitherWay = renderedLineOfNewestFoldedTurn(
            turnCount: Self.turnsBeforeTunedFold, keepRecentTurns: Summarization().keepRecentTurns)
        #expect(narrowedCalls.contains { $0.prompt.contains(foldedEitherWay) })
        #expect(unturnedCalls.contains { $0.prompt.contains(foldedEitherWay) })
    }

    @Test(
        "compact() folds with the Summarization the session was vended with: a doubled summaryTokenRatio doubles the summary allowance every summarizer call is made under"
    )
    @MainActor
    func compactFoldsWithTheSessionsOwnSummaryTokenRatio() async throws {
        let doubled = try await Self.makeSessionReadyToFold(
            responseText: Self.chunkOverflowingText,
            summarization: Summarization(summaryTokenRatio: Summarization().summaryTokenRatio * 2))
        defer { try? FileManager.default.removeItem(at: doubled.directory) }
        let unturned = try await Self.makeSessionReadyToFold(
            responseText: Self.chunkOverflowingText, summarization: Summarization())
        defer { try? FileManager.default.removeItem(at: unturned.directory) }

        let doubledCalls = try await Self.summarizerCallsOfForcedFold(
            doubled.session, container: doubled.container)
        let unturnedCalls = try await Self.summarizerCallsOfForcedFold(
            unturned.session, container: unturned.container)

        // Each ceiling is a summary allowance plus the reasoning headroom, and
        // the ratio sizes the allowance alone — so the allowance is what the
        // knob doubles. Both stages carry the default headroom, so subtracting
        // it reads each allowance back off the number the summarizer was given.
        let headroom = Summarization().reasoningTokenHeadroom
        let doubledAllowance = try #require(doubledCalls.compactMap(\.maxTokens).max()) - headroom
        let unturnedAllowance = try #require(unturnedCalls.compactMap(\.maxTokens).max()) - headroom
        #expect(doubledAllowance == unturnedAllowance * 2)
        // Read off the ratio and not the floor: an allowance squeezed down to
        // `minimumSummaryTokens` would be the same number whatever the ratio is.
        #expect(unturnedAllowance > Summarization.minimumSummaryTokens)
    }

    // MARK: - A deterministic-only fold records its checkpoint (task ^h1008kb)

    /// The per-turn measured usage delta the two checkpoint tests below
    /// configure their stub backend with — large against the tiny stub
    /// transcript's own byte-size estimate, so the fold's measured-scale
    /// rescale (``RoutedSessionActor``'s `foldedUsage`) is a real conversion
    /// rather than a near-identity.
    private static let measuredTokensPerCheckpointTurn = 50_000

    /// The resolved working context those tests run against, sized so the
    /// measured per-turn delta above reports a mid-scale `contextFill`.
    private static let checkpointTestContext = 100_000

    @Test(
        "a deterministic-only fold records exactly one new entry carrying a decodable CompactionSegment checkpoint on the measured scale"
    )
    @MainActor
    func deterministicOnlyFoldRecordsOneCheckpointEntry() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(
            responseText: Self.cannedText,
            usageIncrement: (input: Self.measuredTokensPerCheckpointTurn, output: 0))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(
            profile: Self.profile(context: Self.checkpointTestContext), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let budget = deterministicFoldBudget(for: backend.transcriptEntries())

        let beforeEvents = await recorder.events
        let result = try await session.compact(budget: budget)

        // The fold under test really was deterministic-only: no summarizer
        // ran and no summary entry exists for the diff to pick up.
        #expect(result.stagesApplied == [ToolOutputElision.stageName, TurnTruncation.stageName])
        #expect(result.summary == nil)

        // Exactly one new recorded entry, appended after the untouched prefix.
        let afterEvents = await recorder.events
        #expect(afterEvents.count == beforeEvents.count + 1)
        #expect(Array(afterEvents.prefix(beforeEvents.count)) == beforeEvents)

        // That entry carries this fold's decodable CompactionSegment
        // checkpoint, and the checkpoint names its own entry in the live
        // window so a restore keeps the boundary itself.
        let (response, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)
        #expect(compactionSegment.content.stagesApplied == result.stagesApplied)
        #expect(!compactionSegment.content.foldedEntryIds.isEmpty)
        #expect(compactionSegment.content.liveWindowEntryIds.contains(response.id))

        // The checkpoint's token counts are on the measured scale — the same
        // numbers the live session now reports through `contextFill` — so a
        // restore reads post-fold usage rather than a pre-fold stamp.
        let expectedMeasuredTokensAfter = Int(
            (Double(Self.measuredTokensPerCheckpointTurn) * Double(result.tokensAfter)
                / Double(result.tokensBefore)).rounded())
        #expect(compactionSegment.content.tokensBefore == Self.measuredTokensPerCheckpointTurn)
        #expect(compactionSegment.content.tokensAfter == expectedMeasuredTokensAfter)
        let postFoldFill = await session.contextFill
        #expect(postFoldFill == Double(expectedMeasuredTokensAfter) / Double(Self.checkpointTestContext))
    }

    @Test(
        "restoring a deterministically folded session seeds the post-fold live window — not the pre-fold history — and restores the post-fold contextFill"
    )
    @MainActor
    func restoreAfterDeterministicOnlyFoldYieldsPostFoldWindowAndFill() async throws {
        let cacheDir = Self.makeTempDir()
        let recordingsDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }

        let container = ConfiguredLLMContainer(
            responseText: Self.cannedText,
            usageIncrement: (input: Self.measuredTokensPerCheckpointTurn, output: 0))
        let router = Self.makeRouter(
            container: container, recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile = try await router.resolve(
            profile: Self.profile(context: Self.checkpointTestContext), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preFoldEntries = backend.transcriptEntries()
        let result = try await session.compact(budget: deterministicFoldBudget(for: preFoldEntries))
        #expect(result.summary == nil)
        let postFoldFill = await session.contextFill

        // The post-fold live window TurnTruncation left: the header plus the
        // newest 4 turns, verbatim.
        let (header, turns) = TranscriptTurns.split(preFoldEntries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        let expectedWindow = header + recent.flatMap(\.entries)

        // "Fresh process": a second, independently constructed Router/profile
        // pointed at the same router id and recordings directory.
        let container2 = ConfiguredLLMContainer(
            responseText: Self.cannedText,
            usageIncrement: (input: Self.measuredTokensPerCheckpointTurn, output: 0))
        let router2 = Self.makeRouter(
            id: router.id, container: container2, recorder: JSONLRecorder(directory: recordingsDir),
            cacheDir: cacheDir, recordingsDir: recordingsDir)
        let profile2 = try await router2.resolve(
            profile: Self.profile(context: Self.checkpointTestContext), reporting: ResolutionProgress())

        let restored = try await profile2.standard.restoreSessionTree(root: session.id)
        #expect(restored.root.id == session.id)

        // The restored backend was seeded with the post-fold live window plus
        // the fold's own boundary entry — never the whole pre-fold history.
        let restoredBackend = try #require(container2.lastBackend)
        let restoredEntries = restoredBackend.transcriptEntries()
        #expect(Array(restoredEntries.dropLast()) == expectedWindow)
        #expect(restoredEntries.count < preFoldEntries.count)
        guard case .response(let boundary)? = restoredEntries.last,
            case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the restored transcript to end in the fold's boundary entry")
            return
        }
        #expect(compactionSegment.content.stagesApplied == result.stagesApplied)

        // `contextFill` restores to the fold's own post-fold measurement,
        // not a pre-fold stamp.
        let restoredFill = await restored.root.contextFill
        #expect(restoredFill == postFoldFill)
    }
}
