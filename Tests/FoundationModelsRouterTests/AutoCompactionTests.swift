import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 8213x39 (auto-compaction opt-in): ``RoutedModel/makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)``'s
/// `budget`/`compactionPrompt` parameters, the proactive fold
/// ``RoutedSessionActor/runTurn(grammar:pendingEvents:ownPrompt:onEvent:_:)``
/// runs before a turn once measured fill reaches the budget's trigger, the
/// reactive compact-and-retry-once recovery
/// ``RoutedSessionActor/runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)``
/// runs on `LanguageModelError.contextSizeExceeded`, the flash-then-own-model
/// summarizer preference, and ``SessionEvent/compaction(_:)`` emission.
///
/// Everything runs against stub ``LoadedLLMContainer``s/``LanguageModelSessionBackend``s,
/// so the suite needs no network and no GPU.
@Suite("Auto-compaction opt-in: makeSession(budget:compactionPrompt:) and retry-once")
struct AutoCompactionTests {
    // MARK: - Stub containers

    /// Vends a single, test-retained ``StubSessionBackend`` per session, with
    /// a container-level `shouldThrow` a test can flip before a fold to make
    /// every backend this container vends from then on fail its summarizer
    /// call.
    private final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let responseText: String
        var shouldThrow: Bool
        private(set) var lastBackend: StubSessionBackend?

        init(responseText: String, shouldThrow: Bool = false) {
            self.responseText = responseText
            self.shouldThrow = shouldThrow
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = StubSessionBackend(responseText: responseText, shouldThrow: shouldThrow, instructions: instructions)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(responseText: responseText, shouldThrow: shouldThrow, entries: Array(transcript))
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

    /// Vends `standard` for the `.standard` slot and `flash` for the `.flash`
    /// slot, so a test can distinguish which slot's model auto-compaction
    /// actually asked to summarize.
    private struct PerSlotModelLoader: ModelLoader {
        let standard: any LoadedLLMContainer
        let flash: any LoadedLLMContainer
        let dimension: Int

        func loadLLM(
            ref: ModelRef,
            slot: ModelSlot,
            context: Int,
            reporting: @escaping @Sendable (DownloadProgress) -> Void
        ) async throws -> any LoadedLLMContainer {
            reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
            return slot == .flash ? flash : standard
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

    /// A long-ish canned response repeated across every warm-up turn, so a
    /// handful of turns' worth of transcript already carries a real,
    /// non-trivial byte-size estimate — mirrors `RoutedSessionCompactTests.cannedText`.
    private static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many warm-up turns ``makeTriggeredSession(budget:)`` drives —
    /// past ``TurnTruncation``'s default 4-turn recency window, so folding
    /// has real old-span content to work with.
    private static let turnCount = 6

    /// The exact entries ``makeTriggeredSession(budget:)``'s warm-up turns
    /// produce, computed without ever running a session — prompt/response
    /// text is fixed regardless of the escalating `usageIncrement` those
    /// turns are driven with, so ``fixedBudget`` can be sized once, up
    /// front, from this alone.
    private static func expectedWarmUpEntries() -> [Transcript.Entry] {
        (0..<turnCount).flatMap { index -> [Transcript.Entry] in
            [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn \(index)"))])),
                .response(
                    Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: cannedText))])),
            ]
        }
    }

    /// The estimated token size of just the warm-up entries' un-foldable
    /// recency window (the newest 4 turns) — the floor no deterministic
    /// stage can fold below, so a `budget.target` under this forces the
    /// model-assisted ``Summarization`` stage (and therefore a real
    /// summarizer call) to run. Mirrors `RoutedSessionCompactTests.recencyWindowOnlyEstimate(_:)`.
    private static func recencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
        let (header, turns) = TranscriptTurns.split(entries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
    }

    /// A budget whose target sits strictly below the warm-up transcript's
    /// own recency-window floor — forcing every fold this suite drives to
    /// need the model-assisted ``Summarization`` stage (and so to actually
    /// call a summarizer), the same ratio `RoutedSessionCompactTests.compactIsAppendOnlyAndPreservesIdentity()`
    /// uses. `trigger: 0.8` matches ``TokenBudget``'s own default.
    private static let fixedBudget: TokenBudget = {
        let recencyOnly = recencyWindowOnlyEstimate(expectedWarmUpEntries())
        return TokenBudget(limit: recencyOnly * 2, trigger: 0.8, target: 0.25)
    }()

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
            .appendingPathComponent("AutoCompactionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func makeRouter(loader: PerSlotModelLoader, recorder: any TranscriptRecorder, cacheDir: URL) -> Router {
        Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: loader
        )
    }

    /// Vends a `profile.standard` session with `budget` and drives
    /// ``turnCount`` warm-up turns whose per-turn measured usage escalates
    /// (30% of the profile's 100,000-token context on the last turn: 90%),
    /// crossing the fixed budget's `0.8` trigger only on the final warm-up
    /// turn — mirrors `ExamplesTests.proactiveCompactionBetweenTurns()`'s
    /// own escalating-usage pattern. By the time this returns, the session's
    /// measured `contextFill` is `0.9`, its backend holds ``turnCount``
    /// turns of real content, and no fold has happened yet — a caller then
    /// drives one more turn (typically via `streamEvents`) to observe the
    /// proactive auto-fold this triggers.
    ///
    /// - Parameter budget: The auto-compaction opt-in to vend the session
    ///   with, or `nil` to opt out (the regression case).
    /// - Returns: The session plus its `standard`/`flash` containers, so a
    ///   test can configure `shouldThrow` on either before driving the
    ///   triggering turn.
    private static func makeTriggeredSession(
        budget: TokenBudget?
    ) async throws -> (session: RoutedSession, standard: ConfiguredLLMContainer, flash: ConfiguredLLMContainer) {
        let dir = Self.makeTempDir()
        let recorder = InMemoryRecorder()
        let standardContainer = ConfiguredLLMContainer(responseText: Self.cannedText)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: Self.stubDimension)
        let router = Self.makeRouter(loader: loader, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession(budget: budget)
        let backend = try #require(standardContainer.lastBackend)

        for turn in 0..<Self.turnCount {
            backend.usageIncrement = (input: (turn + 1) * 15_000, output: 0)
            _ = try await session.respond(to: "turn \(turn)")
        }

        return (session, standardContainer, flashContainer)
    }

    /// Derives a working context tight enough that the reactive retry's own
    /// hardcoded `target: 0.35` sits strictly between `seedEntries`'
    /// recency-window-only estimate and its full pre-fold estimate —
    /// guaranteeing `TurnTruncation` alone lands under target (no need for
    /// the model-assisted `Summarization` stage, which the reactive tests'
    /// own stub backends cannot service). Copied from
    /// `ExamplesTests.reactiveCompactionRecoversFromContextOverflow()`'s own
    /// derivation.
    private static func reactiveRetryContextTokens(_ seedEntries: [Transcript.Entry]) -> Int {
        let (header, turns) = TranscriptTurns.split(seedEntries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        let recencyOnlyEstimate = Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
        let preFoldEstimate = Compactor.estimatedTokenCount(of: Transcript(entries: seedEntries))
        let midTarget = (recencyOnlyEstimate + preFoldEstimate) / 2
        return Int(Double(midTarget) / 0.35)
    }

    /// Drains `session`'s `streamEvents(to:)` for one turn into an array, in
    /// production order.
    private static func collectEvents(_ session: RoutedSession, prompt: String) async throws -> [SessionEvent] {
        try await collect(session.streamEvents(to: prompt, maxTokens: nil))
    }

    /// Drains `stream` into an array, in order — mirrors `SessionEventStreamTests.collect(_:)`.
    private static func collect(_ stream: AsyncThrowingStream<SessionEvent, Error>) async throws -> [SessionEvent] {
        var events: [SessionEvent] = []
        for try await event in stream {
            events.append(event)
        }
        return events
    }

    // MARK: - Proactive fold, preferring flash

    @Test(
        "a session vended with a budget proactively folds before a turn once measured fill reaches the trigger, summarizing with the profile's flash slot"
    )
    @MainActor
    func proactiveFoldPrefersFlashSummarizer() async throws {
        let (session, _, _) = try await Self.makeTriggeredSession(budget: Self.fixedBudget)

        // contextFill is 0.9 (>= the 0.8 trigger) after the warm-up turns —
        // the very next turn should fold automatically, before its own work
        // runs, with no caller-side compact() call anywhere in this test.
        #expect(await session.contextFill == 0.9)

        let events = try await Self.collectEvents(session, prompt: "turn 6")

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        // The summary text is flash's own canned response — proof flash,
        // not the session's own model, actually produced it.
        #expect(result.summary == "FLASH-SUMMARY")

        // The triggering turn's own work still ran normally afterward.
        #expect(events.contains(.textDelta(Self.cannedText)))
    }

    // MARK: - Fallback to the session's own model

    @Test(
        "when the flash summarizer fails, auto-compaction falls back to the session's own model"
    )
    @MainActor
    func proactiveFoldFallsBackToOwnModelWhenFlashFails() async throws {
        let (session, standard, flash) = try await Self.makeTriggeredSession(budget: Self.fixedBudget)
        flash.shouldThrow = true
        // The session's own live backend (driving the warm-up turns above)
        // is untouched, so the own-model fallback tier succeeds.
        #expect(standard.lastBackend?.shouldThrow == false)

        let events = try await Self.collectEvents(session, prompt: "turn 6")

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        // The summary text is the session's own canned response, not
        // flash's — proof the own-model tier, not flash, produced it.
        #expect(result.summary == Self.cannedText)

        // The triggering turn's own work still ran normally afterward.
        #expect(events.contains(.textDelta(Self.cannedText)))
    }

    // MARK: - Opt-out regression

    @Test("a session vended with no budget never auto-compacts, regardless of measured fill")
    @MainActor
    func noBudgetMeansNoAutoCompaction() async throws {
        let (session, _, _) = try await Self.makeTriggeredSession(budget: nil)
        #expect(await session.contextFill == 0.9)

        let events = try await Self.collectEvents(session, prompt: "turn 6")

        #expect(!events.contains { if case .compaction = $0 { return true }; return false })
    }

    // MARK: - Fork inherits the opt-in

    @Test("a fork inherits its parent's auto-compaction budget and folds on its own first turn if inherited fill is already at trigger")
    @MainActor
    func forkInheritsAutoCompactionBudget() async throws {
        let (session, _, _) = try await Self.makeTriggeredSession(budget: Self.fixedBudget)
        #expect(await session.contextFill == 0.9)

        let forked = try await session.fork(workingDirectory: nil)
        // The fork inherits the parent's measured fill as of fork time
        // (already at/above trigger), so its very first turn should fold
        // proactively before running, with no warm-up of its own.
        #expect(await forked.contextFill == 0.9)

        let events = try await Self.collectEvents(forked, prompt: "fork turn")

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the fork's first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
    }

    // MARK: - Reactive retry-once on context overflow

    /// A backend that throws `LanguageModelError.contextSizeExceeded` for
    /// its first `overflowsRemaining` calls, then succeeds — driving the
    /// reactive auto-compaction retry path with no caller-side catch,
    /// unlike `ExamplesTests`'s manually-driven reactive pattern.
    ///
    /// `@unchecked Sendable` invariant: every mutable property is touched
    /// only from inside `RoutedSessionActor`'s isolated methods, which
    /// serialize every call onto the actor's own executor — mirrors
    /// `ExamplesTests.OverflowOnceBackend`'s own documented invariant.
    private final class ScriptedOverflowBackend: LanguageModelSessionBackend, @unchecked Sendable {
        let responseText: String
        private(set) var entries: [Transcript.Entry]
        private var overflowsRemaining: Int
        let replaceSpy: ReplaceSpy
        /// Shared across every clone this backend produces (``makeFork()``,
        /// ``replacingTranscript(_:)``) — unlike a plain instance counter,
        /// which would reset to a misleadingly-fresh `0` on the very fold
        /// that swaps in the retry's own backend instance, this keeps one
        /// running count across the whole logical turn regardless of how
        /// many physical backend objects served it.
        let callLog: CallLog

        init(
            responseText: String,
            entries: [Transcript.Entry] = [],
            overflowsRemaining: Int,
            replaceSpy: ReplaceSpy = ReplaceSpy(),
            callLog: CallLog = CallLog()
        ) {
            self.responseText = responseText
            self.entries = entries
            self.overflowsRemaining = overflowsRemaining
            self.replaceSpy = replaceSpy
            self.callLog = callLog
        }

        static func seedEntries(turnCount: Int, responseText: String) -> [Transcript.Entry] {
            (0..<turnCount).flatMap { index -> [Transcript.Entry] in
                [
                    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "seed turn \(index)"))])),
                    .response(
                        Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))])),
                ]
            }
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            callLog.increment()
            if overflowsRemaining > 0 {
                overflowsRemaining -= 1
                throw LanguageModelError.contextSizeExceeded(
                    .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
            }
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            entries.append(
                .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))])))
            return responseText
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(responseText)
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            responseText
        }

        func makeFork() -> any LanguageModelSessionBackend {
            ScriptedOverflowBackend(
                responseText: responseText, entries: entries, overflowsRemaining: overflowsRemaining, replaceSpy: replaceSpy,
                callLog: callLog)
        }

        func transcriptEntries() -> [Transcript.Entry] { entries }

        func usageTokenCounts() -> (input: Int, output: Int)? { nil }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            replaceSpy.recordReplace()
            return ScriptedOverflowBackend(
                responseText: responseText, entries: Array(transcript), overflowsRemaining: overflowsRemaining,
                replaceSpy: replaceSpy, callLog: callLog)
        }
    }

    /// Counts how many times a ``ScriptedOverflowBackend``'s
    /// ``ScriptedOverflowBackend/replacingTranscript(_:)`` was called — the
    /// only way to observe, from outside the session, that the reactive
    /// retry's own fold actually performed a genuine fold. Mirrors
    /// `ExamplesTests.ReplaceSpy`.
    private final class ReplaceSpy: @unchecked Sendable {
        private(set) var replaceCount = 0
        func recordReplace() { replaceCount += 1 }
    }

    /// Counts every `respond(to:maxTokens:)` call across a
    /// ``ScriptedOverflowBackend`` and every clone it produces — see that
    /// type's own ``ScriptedOverflowBackend/callLog`` doc comment for why a
    /// plain per-instance counter cannot answer "how many physical attempts
    /// did this logical turn take" once a fold swaps in a new instance
    /// mid-turn.
    private final class CallLog: @unchecked Sendable {
        private(set) var count = 0
        func increment() { count += 1 }
    }

    /// A container vending a single, test-retained ``ScriptedOverflowBackend``.
    private final class OverflowLLMContainer: LoadedLLMContainer, @unchecked Sendable {
        let responseText: String
        let seedEntries: [Transcript.Entry]
        let overflowsRemaining: Int
        let replaceSpy = ReplaceSpy()
        let callLog = CallLog()
        private(set) var lastBackend: ScriptedOverflowBackend?

        init(responseText: String, seedEntries: [Transcript.Entry], overflowsRemaining: Int) {
            self.responseText = responseText
            self.seedEntries = seedEntries
            self.overflowsRemaining = overflowsRemaining
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = ScriptedOverflowBackend(
                responseText: responseText, entries: seedEntries, overflowsRemaining: overflowsRemaining,
                replaceSpy: replaceSpy, callLog: callLog)
            lastBackend = backend
            return backend
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            ScriptedOverflowBackend(
                responseText: responseText, entries: Array(transcript), overflowsRemaining: 0, replaceSpy: replaceSpy,
                callLog: callLog)
        }
    }

    @Test(
        "a session with a budget recovers automatically from LanguageModelError.contextSizeExceeded: fold harder, retry once, no caller-side catch needed"
    )
    @MainActor
    func reactiveRetryRecoversFromContextOverflowAutomatically() async throws {
        let dir = Self.makeTempDir()
        let recorder = InMemoryRecorder()
        let seedEntries = ScriptedOverflowBackend.seedEntries(turnCount: 6, responseText: Self.cannedText)
        let standardContainer = OverflowLLMContainer(
            responseText: "recovered", seedEntries: seedEntries, overflowsRemaining: 1)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: Self.stubDimension)
        let router = Self.makeRouter(loader: loader, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        // A budget whose trigger will never fire proactively (usage is
        // unmeasured — `usageTokenCounts()` always `nil` — so fill stays at
        // its unmeasured/zero starting point) — isolating the *reactive*
        // path this test targets from the proactive one. `target: 0.35`'s
        // own `limit` is derived from the seeded transcript's own estimated
        // size (mirrors `ExamplesTests.reactiveCompactionRecoversFromContextOverflow()`),
        // guaranteeing the lowered-target retry fold actually drops
        // something real (`TurnTruncation` alone lands under it) rather
        // than no-op'ing on an already-under-target transcript.
        let session = profile.standard.makeSession(budget: TokenBudget(limit: Self.reactiveRetryContextTokens(seedEntries), target: 0.35))

        // No `do`/`catch` here at all — unlike `ExamplesTests.respondWithReactiveCompaction`,
        // which the caller must wrap manually, this session recovers on its
        // own.
        let response = try await session.respond(to: "keep going")

        #expect(response == "recovered")
        // The backend was called twice: the overflowing first attempt, then
        // the retry — never a third time.
        #expect(standardContainer.callLog.count == 2)
        // The reactive fold genuinely swapped the backend (a real fold, not
        // a no-op) before the retry ran.
        #expect(standardContainer.replaceSpy.replaceCount == 1)
    }

    @Test(
        "a session with a budget surfaces LanguageModelError.contextSizeExceeded after exactly one failed retry, never looping"
    )
    @MainActor
    func reactiveRetrySurfacesAfterOneFailedRetry() async throws {
        let dir = Self.makeTempDir()
        let recorder = InMemoryRecorder()
        let seedEntries = ScriptedOverflowBackend.seedEntries(turnCount: 6, responseText: Self.cannedText)
        // Overflows on every call this test could plausibly make (initial +
        // the one retry) — proving the session gives up after one retry
        // rather than looping.
        let standardContainer = OverflowLLMContainer(
            responseText: "unreachable", seedEntries: seedEntries, overflowsRemaining: 1_000)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: Self.stubDimension)
        let router = Self.makeRouter(loader: loader, recorder: recorder, cacheDir: dir)
        let profile = try await router.resolve(profile: Self.profile(context: 100_000), reporting: ResolutionProgress())

        let session = profile.standard.makeSession(budget: TokenBudget(limit: 100_000, target: 0.35))

        var caughtOverflow = false
        do {
            _ = try await session.respond(to: "keep going")
        } catch LanguageModelError.contextSizeExceeded {
            caughtOverflow = true
        }

        #expect(caughtOverflow)
        // Exactly two attempts: the original call plus the one retry.
        #expect(standardContainer.callLog.count == 2)
    }
}
