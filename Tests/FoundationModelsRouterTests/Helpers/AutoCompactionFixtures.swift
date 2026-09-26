import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Vends a single, test-retained ``StubSessionBackend`` per session, with a
/// container-level ``shouldThrow`` a test can flip before a compaction to make every
/// backend this container vends from then on fail its summarizer call.
///
/// Flipping ``shouldThrow`` reaches only the backends vended *after* the flip,
/// because ``StubSessionBackend`` copies the flag it was built with. That is
/// what makes the flash tier fail on its own: an automatic compaction builds the
/// flash summarizer through `makeSession(instructions:)`, so the flip reaches
/// it. To make a session's *own* model fail, flip ``lastBackend``'s own flag
/// instead — the own-model tier builds its summarizer from the live backend
/// through `replacingTranscript(_:)`, which carries that backend's flag.
///
/// `@unchecked Sendable` invariant: every mutable property is touched only
/// between answers from test code, or from inside ``RoutedSessionActor``'s
/// isolated methods, which serialize every call onto the actor's own executor.
final class ConfiguredLLMContainer: LoadedLLMContainer, @unchecked Sendable {
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The canned text every backend this container vends answers with.
    let responseText: String

    /// Whether every backend vended from now on throws instead of answering.
    var shouldThrow: Bool

    /// The shared log every backend this container vends records into —
    /// including the blank-slate clone a compaction's summarizer builds through
    /// `replacingTranscript(_:)`. On the `flash` container this holds an
    /// automatic compaction's own summarizer calls and nothing else, since a
    /// warm-up answer never reaches the flash slot.
    let generationLog = StubGenerationLog()

    /// The backend the most recent `makeSession(instructions:)` vended, so a
    /// test can configure the session's own live backend after it exists.
    private(set) var lastBackend: StubSessionBackend?

    /// The sampling mode each mode-carrying `makeSession` received, in call
    /// order. The signatures with no mode record nothing, so a caller that
    /// skips the mode leaves a gap in this list.
    private(set) var receivedSamplingModes: [GenerationOptions.SamplingMode?] = []

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

    /// Records `samplingMode` and vends through ``makeSession(instructions:)``.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`.
    /// - Returns: The vended backend.
    func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        receivedSamplingModes.append(samplingMode)
        return makeSession(instructions: instructions)
    }

    /// Ignores `tools` and forwards to ``makeSession(instructions:samplingMode:)``.
    func makeSession(
        instructions: String?, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, samplingMode: samplingMode)
    }

    /// Records `samplingMode` and vends through ``makeSession(transcript:)``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the backend from.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`.
    /// - Returns: The vended backend.
    func makeSession(
        transcript: Transcript, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        receivedSamplingModes.append(samplingMode)
        return makeSession(transcript: transcript)
    }

    /// Ignores `tools` and forwards to ``makeSession(transcript:samplingMode:)``.
    func makeSession(
        transcript: Transcript, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, samplingMode: samplingMode)
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

/// The shared warm-up every auto-compaction suite compacts against: a session
/// whose measured fill has already reached its budget's trigger, over a
/// two-slot profile whose `standard` and `flash` containers a test can
/// configure independently.
///
/// One home for the fixture, so the suites that drive an automatic compaction —
/// `AutoCompactionTests` and `CompactionTracingTests` — warm up exactly the
/// same way and their budgets keep meaning the same thing.
enum AutoCompactionFixtures {
    /// A long canned response repeated across every warm-up answer, so a
    /// handful of answers' worth of transcript already carries a real,
    /// non-trivial byte-size estimate — mirrors `RoutedSessionCompactTests.cannedText`.
    ///
    /// The length is load-bearing for
    /// `AutoCompactionTests.hardCeilingFailsFastThenRecoversWithLivePerAttemptFill()`,
    /// which needs the retry's compaction to shrink the transcript by enough that
    /// the retry's own pre-check clears a ceiling the blocked attempt tripped.
    /// A compaction replaces the old span with one synthesized summary entry, and
    /// that entry costs its summary text plus its `CompactionSegment`'s own
    /// live-window/compacted entry-id manifest — a fixed cost of roughly 175
    /// estimated tokens with these fixtures' UUID entry ids. At 12 repetitions
    /// the whole warm-up transcript estimated 819 tokens and a compaction left 776:
    /// the manifest ate two thirds of the old span it replaced, so the compaction
    /// was a 5% shrink and no ceiling could sit between it and the blocked
    /// attempt's own fill.
    static let cannedText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: cannedTextRepeatCount)

    /// The number of times ``cannedText`` repeats its sentence.
    ///
    /// Keep this count large. Each compaction must make the transcript much smaller
    /// than the cost of the summary entry's own manifest. The documentation of
    /// ``cannedText`` gives the measurements that set this number.
    private static let cannedTextRepeatCount = 60

    /// How many warm-up answers
    /// ``makeTriggeredSession(budget:tools:summarization:tracer:samplingMode:tempDirPrefix:)``
    /// drives. The warm-up transcript then holds many copies of
    /// ``cannedText``, so a summary of one copy makes it much smaller.
    static let answerCount = 6

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
    /// measured usage on its first answer, growing by the same step each
    /// answer — 15% an answer over ``answerCount`` answers reaches 90%, so the
    /// warm-up crosses ``fixedBudgetTriggerFraction`` only on the final warm-up
    /// answer.
    private static let warmUpUsageStepTokens = 15_000

    /// The fraction of ``fixedBudget``'s limit at which auto-compaction starts.
    ///
    /// This value is the same as ``TokenBudget``'s own default trigger. The
    /// escalating warm-up crosses it only on the last warm-up answer.
    private static let fixedBudgetTriggerFraction = 0.8

    /// A budget whose target is under the warm-up transcript, so every
    /// compaction it drives calls a summarizer. The target in tokens is the one
    /// ``summarizingCompactionBudget(for:)`` gives the warm-up transcript. The
    /// trigger is ``fixedBudgetTriggerFraction``, and `limit` is
    /// ``warmUpContextTokens`` so the trigger fires exactly where the
    /// escalating warm-up's own `contextFill` readings say it does; `target` is
    /// that target expressed as a fraction of this limit.
    static let fixedBudget: TokenBudget = {
        let targetTokens = summarizingCompactionBudget(for: expectedWarmUpEntries()).targetTokens
        return TokenBudget(
            limit: warmUpContextTokens,
            trigger: fixedBudgetTriggerFraction,
            target: Double(targetTokens) / Double(warmUpContextTokens)
        )
    }()

    /// The exact entries
    /// ``makeTriggeredSession(budget:tools:summarization:tracer:samplingMode:tempDirPrefix:)``'s
    /// warm-up answers produce, computed without ever running a session —
    /// prompt/response text is fixed regardless of the escalating usage those
    /// answers are driven with, so ``fixedBudget`` can be sized once, up front,
    /// from this alone.
    ///
    /// - Returns: The warm-up transcript, in order.
    static func expectedWarmUpEntries() -> [Transcript.Entry] {
        (0..<answerCount).flatMap { index -> [Transcript.Entry] in
            [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "message \(index)"))])),
                .response(
                    Transcript.Response(segments: [.text(Transcript.TextSegment(content: cannedText))])),
            ]
        }
    }

    /// Vends a `profile.standard` session with `budget` and drives
    /// ``answerCount`` warm-up answers whose measured usage for each answer
    /// escalates (30% of the profile's 100,000-token context on the last
    /// answer: 90%), crossing ``fixedBudgetTriggerFraction`` only on the final
    /// warm-up answer — mirrors `ExamplesTests.proactiveCompactionBetweenAnswers()`'s
    /// own escalating-usage pattern. By the time this returns, the session's
    /// measured `contextFill` is `0.9`, its backend holds ``answerCount``
    /// answers of real content, and no compaction has happened yet — a caller
    /// then drives one more answer (typically via `streamEvents`) to observe the
    /// proactive auto-compaction this triggers, or calls
    /// ``RoutedSession/compact(prompt:budget:)`` to drive a compaction of its own.
    ///
    /// - Parameters:
    ///   - budget: The auto-compaction opt-in to vend the session with, or
    ///     `nil` to opt out (the regression case, and the way a caller-driven
    ///     compaction is left as the only compaction that runs).
    ///   - tools: The tools to vend the session with. Defaults to none.
    ///   - summarization: The summarization stage every compaction on the vended
    ///     session runs with. Defaults to `Summarization()`.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    ///   - samplingMode: The decoding strategy the router passes to every
    ///     backend it makes, or `nil` (the default) for the provider default.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The session plus its `standard`/`flash` containers, so a
    ///   test can configure either before driving the compaction.
    /// - Throws: Whatever profile resolution or a warm-up answer throws.
    static func makeTriggeredSession(
        budget: TokenBudget?,
        tools: [any Tool] = [],
        summarization: Summarization = Summarization(),
        tracer: (any Tracer)? = nil,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        tempDirPrefix: String
    ) async throws -> (session: RoutedSession, standard: ConfiguredLLMContainer, flash: ConfiguredLLMContainer) {
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let (session, standardContainer) = try await makeTriggeredSession(
            budget: budget, tools: tools, summarization: summarization, tracer: tracer,
            samplingMode: samplingMode, flash: flashContainer, tempDirPrefix: tempDirPrefix)
        return (session, standardContainer, flashContainer)
    }

    /// ``makeTriggeredSession(budget:tools:summarization:tracer:samplingMode:tempDirPrefix:)``
    /// over a `flash` container that the caller gives, so a test can watch
    /// the flash summarizer call on a container of its own choice.
    ///
    /// - Parameters:
    ///   - budget: The auto-compaction opt-in to vend the session with, or
    ///     `nil` to opt out.
    ///   - tools: The tools to vend the session with. Defaults to none.
    ///   - summarization: The summarization stage every compaction on the vended
    ///     session runs with. Defaults to `Summarization()`.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    ///   - samplingMode: The decoding strategy the router passes to every
    ///     backend it makes, or `nil` (the default) for the provider default.
    ///   - flashContainer: The container the `.flash` slot resolves to.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The session plus its `standard` container.
    /// - Throws: Whatever profile resolution or a warm-up answer throws.
    static func makeTriggeredSession(
        budget: TokenBudget?,
        tools: [any Tool] = [],
        summarization: Summarization = Summarization(),
        tracer: (any Tracer)? = nil,
        samplingMode: GenerationOptions.SamplingMode? = nil,
        flash flashContainer: any LoadedLLMContainer,
        tempDirPrefix: String
    ) async throws -> (session: RoutedSession, standard: ConfiguredLLMContainer) {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let standardContainer = ConfiguredLLMContainer(responseText: cannedText)
        let loader = PerSlotModelLoader(
            standard: standardContainer, flash: flashContainer, dimension: RouterTestFixtures.stubDimension)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir, recorder: recorder, loader: loader, tracer: tracer, samplingMode: samplingMode)
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: warmUpContextTokens), reporting: ResolutionProgress())

        let session = profile.standard.makeSession(
            tools: tools, budget: budget, summarization: summarization)
        let backend = try #require(standardContainer.lastBackend)

        for answer in 0..<answerCount {
            backend.usageIncrement = (input: (answer + 1) * warmUpUsageStepTokens, output: 0)
            _ = try await session.respond(to: "message \(answer)")
        }

        return (session, standardContainer)
    }
}
