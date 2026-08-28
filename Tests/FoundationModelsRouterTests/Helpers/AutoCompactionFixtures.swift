import Foundation
import FoundationModels
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Vends a single, test-retained ``StubSessionBackend`` per session, with a
/// container-level ``shouldThrow`` a test can flip before a fold to make every
/// backend this container vends from then on fail its summarizer call.
///
/// Flipping ``shouldThrow`` reaches only the backends vended *after* the flip,
/// because ``StubSessionBackend`` copies the flag it was built with. That is
/// what makes the flash tier fail on its own: an automatic fold builds the
/// flash summarizer through `makeSession(instructions:)`, so the flip reaches
/// it. To make a session's *own* model fail, flip ``lastBackend``'s own flag
/// instead — the own-model tier builds its summarizer from the live backend
/// through `replacingTranscript(_:)`, which carries that backend's flag.
///
/// `@unchecked Sendable` invariant: every mutable property is touched only
/// between turns from test code, or from inside ``RoutedSessionActor``'s
/// isolated methods, which serialize every call onto the actor's own executor.
final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
    /// The canned text every backend this container vends answers with.
    let responseText: String

    /// Whether every backend vended from now on throws instead of answering.
    var shouldThrow: Bool

    /// The shared log every backend this container vends records into —
    /// including the blank-slate clone a fold's summarizer builds through
    /// `replacingTranscript(_:)`. On the `flash` container this holds an
    /// automatic fold's own summarizer calls and nothing else, since a
    /// warm-up turn never reaches the flash slot.
    let generationLog = StubGenerationLog()

    /// The backend the most recent `makeSession(instructions:)` vended, so a
    /// test can configure the session's own live backend after it exists.
    private(set) var lastBackend: StubSessionBackend?

    /// Creates a container.
    ///
    /// - Parameters:
    ///   - responseText: The canned text every vended backend answers with.
    ///   - shouldThrow: Whether every vended backend throws instead of
    ///     answering. Defaults to `false`.
    init(responseText: String, shouldThrow: Bool = false) {
        self.responseText = responseText
        self.shouldThrow = shouldThrow
    }

    /// Vends a fresh backend and retains it as ``lastBackend``.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: The vended backend.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        let backend = StubSessionBackend(
            responseText: responseText, shouldThrow: shouldThrow, instructions: instructions,
            generationLog: generationLog)
        lastBackend = backend
        return backend
    }

    /// Vends a fresh backend seeded from `transcript`.
    ///
    /// - Parameter transcript: The transcript to seed the backend from.
    /// - Returns: The vended backend.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(
            responseText: responseText, shouldThrow: shouldThrow, entries: Array(transcript),
            generationLog: generationLog)
    }
}

/// Vends `standard` for the `.standard` slot and `flash` for the `.flash`
/// slot, so a test can distinguish which slot's model auto-compaction
/// actually asked to summarize.
struct PerSlotModelLoader: ModelLoader {
    /// The container every slot but `.flash` resolves to.
    let standard: any LoadedLLMContainer

    /// The container the `.flash` slot resolves to.
    let flash: any LoadedLLMContainer

    /// The vector length the stub embedder reports.
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

/// The shared warm-up every auto-compaction suite folds against: a session
/// whose measured fill has already reached its budget's trigger, over a
/// two-slot profile whose `standard` and `flash` containers a test can
/// configure independently.
///
/// One home for the fixture, so the suites that drive an automatic fold —
/// `AutoCompactionTests` and `CompactionTracingTests` — warm up exactly the
/// same way and their budgets keep meaning the same thing.
enum AutoCompactionFixtures {
    /// A long canned response repeated across every warm-up turn, so a handful
    /// of turns' worth of transcript already carries a real, non-trivial
    /// byte-size estimate — mirrors `RoutedSessionCompactTests.cannedText`.
    ///
    /// The length is load-bearing for
    /// `AutoCompactionTests.hardCeilingFailsFastThenRecoversWithLivePerAttemptFill()`,
    /// which needs the retry's fold to shrink the transcript by enough that
    /// the retry's own pre-check clears a ceiling the blocked attempt tripped.
    /// A fold replaces the old span with one synthesized summary entry, and
    /// that entry costs its summary text plus its `CompactionSegment`'s own
    /// live-window/folded entry-id manifest — a fixed cost of roughly 175
    /// estimated tokens with these fixtures' UUID entry ids. At 12 repetitions
    /// the whole warm-up transcript estimated 819 tokens and a fold left 776:
    /// the manifest ate two thirds of the old span it replaced, so the fold
    /// was a 5% shrink and no ceiling could sit between it and the blocked
    /// attempt's own fill.
    static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)

    /// How many warm-up turns
    /// ``makeTriggeredSession(budget:tools:summarization:tracer:tempDirPrefix:)``
    /// drives — past ``TurnTruncation``'s default 4-turn recency window, so
    /// folding has real old-span content to work with.
    static let turnCount = 6

    /// The working context every session this fixture vends resolves at — the
    /// denominator of both ``RoutedSession/contextFill`` and, deliberately,
    /// ``fixedBudget``'s own ``TokenBudget/limit``.
    ///
    /// The two must be the same number for the escalating warm-up to mean what
    /// its assertions say: `contextFill` always divides by the session's
    /// resolved context, while ``TokenBudget/triggerTokens`` resolves against
    /// the budget's `limit`, so a budget whose limit is *smaller* than this
    /// would fire its trigger far earlier than any `contextFill` reading
    /// suggests (see ``TokenBudget/triggerTokens``).
    static let warmUpContextTokens = 100_000

    /// The fraction of ``warmUpContextTokens`` the escalating warm-up adds to
    /// measured usage on its first turn, growing by the same step each turn —
    /// 15% a turn over ``turnCount`` turns reaches 90%, so the fixed budget's
    /// `0.8` trigger is crossed only on the final warm-up turn.
    private static let warmUpUsageStepTokens = 15_000

    /// The divisor that puts ``fixedBudget``'s target at half the warm-up
    /// transcript's own recency-window floor — strictly below the floor, so
    /// every fold this budget drives needs the model-assisted
    /// ``Summarization`` stage and really calls a summarizer.
    private static let belowRecencyFloorDivisor = 2

    /// A budget whose target sits strictly below the warm-up transcript's own
    /// recency-window floor — forcing every fold it drives to need the
    /// model-assisted ``Summarization`` stage (and so to actually call a
    /// summarizer), the same ratio
    /// `RoutedSessionCompactTests.compactIsAppendOnlyAndPreservesIdentity()`
    /// uses. `trigger: 0.8` matches ``TokenBudget``'s own default, and `limit`
    /// is ``warmUpContextTokens`` so the trigger fires exactly where the
    /// escalating warm-up's own `contextFill` readings say it does; `target` is
    /// expressed as the fraction of that limit which lands on half the recency
    /// floor.
    static let fixedBudget: TokenBudget = {
        let recencyOnly = recencyWindowOnlyEstimate(expectedWarmUpEntries())
        return TokenBudget(
            limit: warmUpContextTokens,
            trigger: 0.8,
            target: Double(recencyOnly / belowRecencyFloorDivisor) / Double(warmUpContextTokens)
        )
    }()

    /// The exact entries
    /// ``makeTriggeredSession(budget:tools:summarization:tracer:tempDirPrefix:)``'s
    /// warm-up turns produce, computed without ever running a session —
    /// prompt/response text is fixed regardless of the escalating usage those
    /// turns are driven with, so ``fixedBudget`` can be sized once, up front,
    /// from this alone.
    ///
    /// - Returns: The warm-up transcript, in order.
    static func expectedWarmUpEntries() -> [Transcript.Entry] {
        (0..<turnCount).flatMap { index -> [Transcript.Entry] in
            [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "turn \(index)"))])),
                .response(
                    Transcript.Response(segments: [.text(Transcript.TextSegment(content: cannedText))])),
            ]
        }
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
    /// proactive auto-fold this triggers, or calls
    /// ``RoutedSession/compact(prompt:budget:)`` to drive a fold of its own.
    ///
    /// - Parameters:
    ///   - budget: The auto-compaction opt-in to vend the session with, or
    ///     `nil` to opt out (the regression case, and the way a caller-driven
    ///     fold is left as the only fold that runs).
    ///   - tools: The tools to vend the session with. Defaults to none.
    ///   - summarization: The model-assisted stage every fold on the vended
    ///     session runs with. Defaults to `Summarization()` — every default.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The session plus its `standard`/`flash` containers, so a
    ///   test can configure either before driving the fold.
    /// - Throws: Whatever profile resolution or a warm-up turn throws.
    static func makeTriggeredSession(
        budget: TokenBudget?,
        tools: [any Tool] = [],
        summarization: Summarization = Summarization(),
        tracer: (any Tracer)? = nil,
        tempDirPrefix: String
    ) async throws -> (session: RoutedSession, standard: ConfiguredLLMContainer, flash: ConfiguredLLMContainer) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let standardContainer = ConfiguredLLMContainer(responseText: cannedText)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(
            standard: standardContainer, flash: flashContainer, dimension: RouterTestFixtures.stubDimension)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir, recorder: recorder, loader: loader, tracer: tracer)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: warmUpContextTokens), reporting: ResolutionProgress())

        let session = profile.standard.makeSession(
            tools: tools, budget: budget, summarization: summarization)
        let backend = try #require(standardContainer.lastBackend)

        for turn in 0..<turnCount {
            backend.usageIncrement = (input: (turn + 1) * warmUpUsageStepTokens, output: 0)
            _ = try await session.respond(to: "turn \(turn)")
        }

        return (session, standardContainer, flashContainer)
    }
}
