import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises task ffsjqha (compaction epic — compaction_plan.md §1.4,
/// build-order step 6): ``RoutedSession/compact(prompt:budget:)``, the
/// session-level entry point that compacts a ``RoutedSessionActor``'s live
/// transcript in place — the actor counterpart to
/// ``RecordingLanguageModel/noteCompaction(_:)`` for a bare session over the
/// recording handle. The session compacts with
/// ``Compactor/compact(_:prompt:budget:counter:summarizers:summarization:pendingRuns:protection:abandoning:)``,
/// one summarizer call on its own model, and then
/// ``LanguageModelSessionBackend/replacingTranscript(_:)``.
///
/// Everything runs against a stub ``LoadedLLMContainer``/``StubSessionBackend``
/// and an ``InMemoryRecorder``, so the suite needs no network and no GPU. The
/// stub backend answers the summarizer call with its canned text. Budgets
/// come from the real pre-compaction size counted by
/// ``characterTokenCounter``, the suite's own counter, and not from numbers a
/// test picks, so the tests stay correct however the mapper writes an entry.
@Suite("RoutedSession.compact(prompt:budget:): in-place compact on the actor")
struct RoutedSessionCompactTests {
    // MARK: - Stub container

    /// Vends a single, test-retained ``StubSessionBackend`` per session, so a
    /// test can inspect its accumulated entries and derive an exact budget
    /// forcing (or not forcing) a compaction.
    private final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        let responseText: String
        let usageIncrement: (input: Int, output: Int)?

        /// The shared log every backend this container vends records into —
        /// including the blank-slate clone a compaction's summarizer builds through
        /// `replacingTranscript(_:)`, which is the only place a compaction's own
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
            "max_position_embeddings": 8192,
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

    /// The counter the tests size a transcript with: one token per
    /// `Character`, the same rule ``ConfiguredLLMContainer`` counts with.
    private static let characterTokenCounter = CharacterTokenCounter()

    /// A canned response, repeated across every turn and given as the answer
    /// of every summarizer call. Six turns of it are much larger than one
    /// copy, so a summary of this text makes the live context smaller.
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
        recordingsDir: URL? = nil,
        pool: ModelPool = ModelPool()
    ) -> Router {
        Router(
            id: id,
            cacheDir: cacheDir,
            recordingsDir: recordingsDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
    }

    // MARK: - The flash summarizer carries the router's sampling mode

    /// `model-pool.md` §2.5 step A: the flash summarizer is the one backend
    /// a compaction builds from a container, so it is where a router's sampling
    /// mode would be lost. The compaction path is the automatic one: a caller-driven
    /// `compact()` compacts on the session's own live backend and builds no
    /// backend from a container.
    @Test("an automatic compaction's flash summarizer backend receives the router's sampling mode")
    @MainActor
    func autoCompactionFlashSummarizerReceivesTheRoutersSamplingMode() async throws {
        let (session, standard, flash) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget,
            samplingMode: .greedy,
            tempDirPrefix: "RoutedSessionCompactTests")
        // The root session's own backend already carries the mode, and no
        // compaction has asked the flash slot for a backend yet.
        #expect(standard.receivedSamplingModes == [.greedy])
        #expect(flash.receivedSamplingModes.isEmpty)

        // Measured fill sits at the trigger, so this turn compacts before its own
        // work runs, summarizing through the flash slot.
        _ = try await session.respond(to: "turn 6")

        #expect(flash.receivedSamplingModes == [.greedy])
    }

    // MARK: - Shrinks the live window; accurate result

    @Test("compact() shrinks the live window (post-compact contextFill < pre-compact) and returns an accurate CompactionResult")
    @MainActor
    func compactShrinksLiveWindowAndReportsAccurateResult() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        // A large per-turn usage delta relative to the tiny stub transcript's
        // own token count — simulating a session whose measured fill
        // is already high (why compaction would run), on a fixed scale that
        // stays comparable across the two turns driven below.
        let container = ConfiguredLLMContainer(responseText: Self.cannedText, usageIncrement: (input: 50_000, output: 0))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        // Six turns of the canned text are much larger than the one copy of
        // it the summarizer answers with, so the summary shrinks the context.
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preCompactionTokens = try Self.characterTokenCounter.count(Transcript(entries: backend.transcriptEntries()))
        let preCompactionFill = await session.contextFill
        // A turn's own usage delta reports the *whole* transcript's size at
        // that point (generation is stateless) — not a cumulative sum across
        // turns — so with a constant 50,000-token delta per turn against a
        // 100,000-token context, fill sits at 0.5 regardless of turn count.
        #expect(preCompactionFill == 0.5)

        // A target under the live context, so the compaction makes its one
        // summarizer call.
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())
        let result = try await session.compact(budget: budget)

        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(result.tokensBefore == preCompactionTokens)
        #expect(result.tokensAfter < result.tokensBefore)
        // A caller compaction summarizes with the session's own model only.
        #expect(result.summarizerTier == .ownModel)

        let postCompactionFill = await session.contextFill
        #expect(postCompactionFill < preCompactionFill)
        // The post-compaction fill reflects this compaction's own shrink ratio applied to
        // the measured usage the session already had — `tokensAfter` is the
        // pipeline's own count, and `contextFill`'s numerator is measured
        // tokens, so the count is rescaled onto that scale before it is
        // reported (see `RoutedSessionActor.compactedUsage`).
        let expectedPostCompactionTokens = (50_000.0 * Double(result.tokensAfter) / Double(preCompactionTokens)).rounded()
        #expect(postCompactionFill == expectedPostCompactionTokens / 100_000)
    }

    // MARK: - A compaction's reported fill is measured, not the pipeline's own count

    @Test("a compaction never raises contextFill, even when the pipeline's own count of the compacted transcript exceeds the session's measured usage")
    @MainActor
    func compactionReportsShrinkOnTheMeasuredScale() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        // A *small* per-turn measured usage against a transcript the
        // pipeline's own counter sizes far higher — the arrangement that
        // exposed the unit mismatch on real hardware, where an over-counting
        // character-ratio estimate (the count of that time) written into
        // `contextFill`'s numerator made a genuine compaction
        // report a *higher* fill than the measured one it replaced (0.95068
        // after a compaction from 0.89453). The compaction's own accounting has to be
        // denominated in the same tokens the pre-compaction fill was, or a caller
        // comparing the two compares incommensurable numbers.
        let measuredTokensPerTurn = 200
        let container = ConfiguredLLMContainer(
            responseText: Self.cannedText, usageIncrement: (input: measuredTokensPerTurn, output: 0))
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preCompactionTokens = try Self.characterTokenCounter.count(Transcript(entries: backend.transcriptEntries()))
        let preCompactionFill = await session.contextFill

        // The same budget `compactShrinksLiveWindowAndReportsAccurateResult`
        // uses, so what this test measures is the unit the shrink is reported
        // in and nothing else.
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())
        let result = try await session.compact(budget: budget)
        #expect(result.tokensAfter < result.tokensBefore)
        // The premise of this test: the counter's size of the new snapshot is
        // larger than everything the session has measured, so to report the
        // compaction's own count raw could only raise fill.
        #expect(result.tokensAfter > measuredTokensPerTurn)

        let postCompactionFill = await session.contextFill
        #expect(postCompactionFill < preCompactionFill)
        let expectedPostCompactionTokens =
            (Double(measuredTokensPerTurn) * Double(result.tokensAfter) / Double(preCompactionTokens)).rounded()
        #expect(postCompactionFill == expectedPostCompactionTokens / 100_000)
    }

    // MARK: - Identity + append-only recording

    @Test("compact() preserves session id and recordingDirectory; prior recorded events are untouched and the compaction's summary entry is appended")
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
        // A target under the live context: the summarizer call runs and the
        // compaction writes a summary entry.
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())

        let beforeEvents = await recorder.events
        #expect(!beforeEvents.isEmpty)

        let result = try await session.compact(budget: budget)
        #expect(result.summary != nil)
        #expect(result.stagesApplied == [Summarization.stageName])
        // A manual compact() always summarizes with the session's own model,
        // and the result names it — the same signal an automatic compaction carries
        // (task ^59fd9rt).
        #expect(result.summarizerModel == "org/std-a")

        // Identity: requirement 4.
        #expect(session.id == sessionId)
        #expect(session.recordingDirectory == recordingDirectory)

        // Append-only: requirement 2 — nothing before the compaction is touched.
        let afterEvents = await recorder.events
        #expect(afterEvents.count > beforeEvents.count)
        #expect(Array(afterEvents.prefix(beforeEvents.count)) == beforeEvents)

        // The appended entry carries a CompactionSegment.
        let appended = try #require(afterEvents.last)
        #expect(appended.kind == .prompt)
        #expect(appended.sessionId == sessionId)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .prompt(let boundary) = rebuilt, case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .custom CompactionSegment")
            return
        }
        #expect(compactionSegment.content.stagesApplied == [Summarization.stageName])
        #expect(!compactionSegment.content.compactedEntryIds.isEmpty)
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
        let preCompactionTokens = try Self.characterTokenCounter.count(Transcript(entries: backend.transcriptEntries()))
        let budget = TokenBudget(limit: preCompactionTokens * 2, target: 0.25)
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
        // the size of the live context is known before the test picks a
        // context whose *default* budget (the default target of this
        // profile's own context) is just under that size.
        let scratchProfile = try await router.resolve(
            profile: Self.profile(context: 1_000_000), reporting: ResolutionProgress())
        let scratchSession = scratchProfile.standard.makeSession()
        try await driveTurns(6, on: scratchSession)
        let scratchBackend = try #require(container.lastBackend)
        let liveTokens = characterCount(of: scratchBackend.transcriptEntries())

        // A fresh router/profile whose resolved context puts the default
        // budget's target one token under the live context.
        let recorder2 = InMemoryRecorder()
        let container2 = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router2 = Self.makeRouter(container: container2, recorder: recorder2, cacheDir: Self.makeTempDir())
        let tightContext = Int((Double(liveTokens - 1) / TokenBudget(limit: liveTokens).target).rounded())
        let profile2 = try await router2.resolve(
            profile: Self.profile(context: tightContext), reporting: ResolutionProgress())
        let session2 = profile2.standard.makeSession()
        try await driveTurns(6, on: session2)

        let result = try await session2.compact()

        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(result.summary != nil)

        // The default prompt's name is what gets recorded in the compaction's
        // CompactionSegment.
        let events = await recorder2.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .prompt(let boundary) = rebuilt, case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
            return
        }
        #expect(compactionSegment.content.promptName == CompactionPrompt.default.name)
        #expect(boundary.id == result.summaryEntryId)
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
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())
        let customPrompt = CompactionPrompt(name: "custom-test-prompt-v1", text: "Summarize tersely.")

        let result = try await session.compact(prompt: customPrompt, budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let events = await recorder.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .prompt(let boundary) = rebuilt, case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
            return
        }
        #expect(compactionSegment.content.promptName == "custom-test-prompt-v1")
    }

    // MARK: - Throwing summarizer leaves the session untouched

    @Test("when the summarizer throws, compact() leaves session id, recordingDirectory, contextFill, and recorded events untouched, and a later respond() still works normally")
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
        // A target under the live context: the summarizer call runs (see
        // compactIsAppendOnlyAndPreservesIdentity).
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())

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
        // exactly as they were before the failed compaction attempt.
        #expect(session.id == sessionId)
        #expect(session.recordingDirectory == recordingDirectory)
        let afterFill = await session.contextFill
        #expect(afterFill == beforeFill)
        let afterEvents = await recorder.events
        #expect(afterEvents == beforeEvents)

        // A subsequent turn still works normally — the session's backend was
        // never swapped for the (failed) compaction attempt's summarizer backend.
        backend.shouldThrow = false
        let response = try await session.respond(to: "still fine")
        #expect(response == Self.cannedText)
    }

    // MARK: - No-op when already under budget

    @Test("compact() with an already-under-target transcript returns an unchanged result and leaves the session untouched")
    @MainActor
    func compactWithNothingToCompactReturnsUnchanged() async throws {
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

    /// The last recorded event's rebuilt boundary `.prompt` — the entry
    /// every applied compaction appends, carrying its ``CompactionSegment``
    /// checkpoint — or records an issue.
    private static func lastRecordedBoundary(
        in recorder: InMemoryRecorder
    ) async throws -> (boundary: Transcript.Prompt, segment: CompactionSegment) {
        let events = await recorder.events
        let appended = try #require(events.last)
        let entryPayload = try #require(appended.entry)
        let rebuilt = try TranscriptEntryMapper.entry(from: entryPayload, kind: appended.kind)
        guard case .prompt(let boundary) = rebuilt, case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the appended entry to carry a .structure CompactionSegment")
            throw StubSessionBackend.StubError.boom
        }
        return (boundary, compactionSegment)
    }


    @Test(
        "compact() with a background run records its completionToken, op, and latest progress in the boundary CompactionSegment and renders them into a model-visible text segment"
    )
    @MainActor
    func compactCarriesBackgroundRunAcrossBoundary() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder = InMemoryRecorder()
        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let latch = RunLatch()
        let token = await trackFakeRun(on: session.mailbox, latch: latch)
        await session.mailbox.updateProgress(completionToken: token, detail: "halfway through")

        let backend = try #require(container.lastBackend)
        // A target under the live context: the summarizer call runs and the
        // compaction writes its boundary entry.
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())

        let result = try await session.compact(budget: budget)
        #expect(result.stagesApplied.contains("Summarization"))

        let (boundary, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)

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

        // The rendered boundary the post-compaction model reads: the header,
        // the summary text, and one more text segment carrying the pending-run
        // summary. It states the push contract — the session reports each
        // run when it settles — and names status/wait for an earlier look.
        let texts = try #require(summaryEntryTexts(of: .prompt(boundary)))
        #expect(texts.first == CompactionSegment.summaryHeader)
        #expect(texts.count == 3)
        let rendering = try #require(texts.last)
        #expect(rendering.contains(token))
        #expect(rendering.contains(FakeRun.op))
        #expect(rendering.contains("halfway through"))
        #expect(rendering.contains("The session reports each run when it settles"))
        #expect(rendering.contains("status()"))
        #expect(!rendering.contains("live view"))

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
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())

        let result = try await session.compact(budget: budget)
        #expect(result.stagesApplied == [Summarization.stageName])

        let (boundary, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)

        #expect(compactionSegment.content.pendingRuns == nil)
        // Exactly the boundary shape with no runs: the header, one summary
        // text segment and the CompactionSegment — no pending-run carrier of
        // any kind.
        #expect(summaryEntryTexts(of: .prompt(boundary)) == [CompactionSegment.summaryHeader, Self.cannedText])
        #expect(boundary.segments.count == 3)
    }

    // MARK: - The one own-model call of a caller compaction

    @Test(
        "compact() makes one call on the session's own model, over the whole live context, with the allowed summary size capped at the room its window leaves after the input"
    )
    @MainActor
    func compactMakesOneOwnModelCallCappedAtTheAllowedSize() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let contextTokens = 100_000

        let container = ConfiguredLLMContainer(responseText: Self.cannedText)
        let router = Self.makeRouter(container: container, recorder: InMemoryRecorder(), cacheDir: dir)
        let profile = try await router.resolve(
            profile: Self.profile(context: contextTokens), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let callsBeforeCompaction = container.generationLog.calls.count
        let entries = backend.transcriptEntries()
        let budget = summarizingCompactionBudget(for: entries)
        let allowedTokens = budget.allowedSummaryTokens(for: entries)
        let result = try await session.compact(budget: budget)

        let calls = Array(container.generationLog.calls.suffix(from: callsBeforeCompaction))
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.maxTokens == min(allowedTokens, contextTokens - call.prompt.count))
        #expect(call.maxTokens == allowedTokens)
        // The summarizer call turns reasoning off (task ^dvyt1dx).
        #expect(call.reasoningOff)
        #expect(call.prompt.contains("User: turn 0"))
        #expect(call.prompt.contains("User: turn 5"))
        #expect(result.summarizerTier == .ownModel)
        #expect(result.summary == Self.cannedText)
    }

    // MARK: - A compaction records its checkpoint (task ^h1008kb)

    /// The per-turn measured usage delta the two checkpoint tests below
    /// configure their stub backend with — large against the tiny stub
    /// transcript's own token count, so the compaction's measured-scale
    /// rescale (``RoutedSessionActor``'s `compactedUsage`) is a real conversion
    /// rather than a near-identity.
    private static let measuredTokensPerCheckpointTurn = 50_000

    /// The resolved working context those tests run against, sized so the
    /// measured per-turn delta above reports a mid-scale `contextFill`.
    private static let checkpointTestContext = 100_000

    @Test(
        "a compaction records exactly one new entry carrying a decodable CompactionSegment checkpoint on the measured scale"
    )
    @MainActor
    func compactionRecordsOneCheckpointEntry() async throws {
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
        let budget = summarizingCompactionBudget(for: backend.transcriptEntries())

        let beforeEvents = await recorder.events
        let result = try await session.compact(budget: budget)

        // The compaction under test wrote a summary: the summary entry is the
        // one new entry the diff picks up.
        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(result.summary != nil)

        // Exactly one new recorded entry, appended after the untouched prefix.
        let afterEvents = await recorder.events
        #expect(afterEvents.count == beforeEvents.count + 1)
        #expect(Array(afterEvents.prefix(beforeEvents.count)) == beforeEvents)

        // That entry carries this compaction's decodable CompactionSegment
        // checkpoint, and the checkpoint names its own entry in the live
        // window so a restore keeps the boundary itself.
        let (boundary, compactionSegment) = try await Self.lastRecordedBoundary(in: recorder)
        #expect(compactionSegment.content.stagesApplied == result.stagesApplied)
        #expect(!compactionSegment.content.compactedEntryIds.isEmpty)
        #expect(compactionSegment.content.liveWindowEntryIds.contains(boundary.id))

        // The checkpoint's token counts are on the measured scale — the same
        // numbers the live session now reports through `contextFill` — so a
        // restore reads post-compaction usage rather than a pre-compaction stamp.
        let expectedMeasuredTokensAfter = Int(
            (Double(Self.measuredTokensPerCheckpointTurn) * Double(result.tokensAfter)
                / Double(result.tokensBefore)).rounded())
        #expect(compactionSegment.content.tokensBefore == Self.measuredTokensPerCheckpointTurn)
        #expect(compactionSegment.content.tokensAfter == expectedMeasuredTokensAfter)
        let postCompactionFill = await session.contextFill
        #expect(postCompactionFill == Double(expectedMeasuredTokensAfter) / Double(Self.checkpointTestContext))
    }

    @Test(
        "restoring a compacted session seeds the instructions and the summary entry — not the pre-compaction history — and restores the post-compaction contextFill"
    )
    @MainActor
    func restoreAfterCompactionYieldsInstructionsAndSummaryAndFill() async throws {
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

        let session = profile.standard.makeSession(instructions: "You are a test assistant.")
        try await driveTurns(6, on: session)

        let backend = try #require(container.lastBackend)
        let preCompactionEntries = backend.transcriptEntries()
        let result = try await session.compact(budget: summarizingCompactionBudget(for: preCompactionEntries))
        let summary = try #require(result.summary)
        let postCompactionFill = await session.contextFill

        // The new snapshot keeps the instructions word for word and no turn of
        // the conversation.
        let expectedWindow = preCompactionEntries.filter {
            if case .instructions = $0 { return true }
            return false
        }
        #expect(!expectedWindow.isEmpty)

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

        // The restored backend was seeded with the instructions plus the
        // compaction's own summary entry — never the whole pre-compaction history.
        let restoredBackend = try #require(container2.lastBackend)
        let restoredEntries = restoredBackend.transcriptEntries()
        #expect(Array(restoredEntries.dropLast()) == expectedWindow)
        #expect(restoredEntries.count < preCompactionEntries.count)
        guard case .prompt(let boundary)? = restoredEntries.last,
            let summaryText = summaryEntryTexts(of: .prompt(boundary))?.dropFirst().first,
            case .structure(let segment)? = boundary.segments.last,
            let compactionSegment = try CompactionSegment(structuredSegment: segment)
        else {
            Issue.record("expected the restored transcript to end in the compaction's summary entry")
            return
        }
        #expect(boundary.id == result.summaryEntryId)
        #expect(summaryText == summary)
        #expect(compactionSegment.content.stagesApplied == result.stagesApplied)

        // `contextFill` restores to the compaction's own post-compaction measurement,
        // not a pre-compaction stamp.
        let restoredFill = await restored.root.contextFill
        #expect(restoredFill == postCompactionFill)
    }
}
