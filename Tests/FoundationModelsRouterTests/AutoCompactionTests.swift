import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task 8213x39 (auto-compaction opt-in): ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``'s
/// `budget`/`compactionPrompt` parameters, the proactive fold
/// ``RoutedSessionActor/runTurn(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)``
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
    // MARK: - Sample tools (task 4ce0a1k): tools + budget composition

    /// Shared arguments for both sample tools below — a single field is
    /// enough to prove wiring; the mechanics under test here are
    /// tools-plus-budget composition, not argument schemas.
    @Generable
    struct SampleToolArguments {
        let text: String
    }

    /// A trivial, always-succeeding `Tool` — returns its input verbatim.
    /// Real tool-calling only happens inside a live `LanguageModelSession`
    /// (this suite's stub backends never invoke it), so this exists purely
    /// to prove `makeSession(tools:budget:)` accepts a real
    /// `FoundationModels.Tool` conformance alongside a budget.
    private struct EchoTool: Tool {
        let name = "echo"
        let description = "returns its input text unchanged"
        func call(arguments: SampleToolArguments) async throws -> String { arguments.text }
    }

    /// A trivial, always-failing `Tool` — proves a tool that could fail is
    /// just as safely threaded alongside a budget as one that always
    /// succeeds; construction/wiring never inspects a tool's own behavior.
    private struct FailingTool: Tool {
        enum Failure: Error, Equatable { case boom }
        let name = "always-fails"
        let description = "a tool that always throws"
        func call(arguments: SampleToolArguments) async throws -> String { throw Failure.boom }
    }

    // MARK: - Fixture content

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "AutoCompactionTests"

    /// The canned response every warm-up turn answers with. See
    /// ``AutoCompactionFixtures/cannedText``.
    private static let cannedText = AutoCompactionFixtures.cannedText

    /// How many warm-up turns each triggered session drives. See
    /// ``AutoCompactionFixtures/turnCount``.
    private static let turnCount = AutoCompactionFixtures.turnCount

    /// The budget every fold this suite drives runs against. See
    /// ``AutoCompactionFixtures/fixedBudget``.
    private static let fixedBudget = AutoCompactionFixtures.fixedBudget

    /// Vends the shared triggered session under this suite's own temp-directory
    /// prefix. See
    /// ``AutoCompactionFixtures/makeTriggeredSession(budget:tools:summarization:tracer:tempDirPrefix:)``.
    ///
    /// - Parameters:
    ///   - budget: The auto-compaction opt-in to vend the session with, or
    ///     `nil` to opt out (the regression case).
    ///   - tools: The tools to vend the session with — see task 4ce0a1k's own
    ///     tools-plus-budget composition tests below. Defaults to none,
    ///     unchanged from every pre-existing test in this suite.
    ///   - summarization: The model-assisted stage every fold on the vended
    ///     session runs with. Defaults to `Summarization()` — every default —
    ///     which is what every test in this suite but the fold-tuning one
    ///     below wants.
    /// - Returns: The session plus its `standard`/`flash` containers, so a
    ///   test can configure `shouldThrow` on either before driving the
    ///   triggering turn.
    /// - Throws: Whatever profile resolution or a warm-up turn throws.
    private static func makeTriggeredSession(
        budget: TokenBudget?,
        tools: [any Tool] = [],
        summarization: Summarization = Summarization()
    ) async throws -> (session: RoutedSession, standard: ConfiguredLLMContainer, flash: ConfiguredLLMContainer) {
        try await AutoCompactionFixtures.makeTriggeredSession(
            budget: budget, tools: tools, summarization: summarization, tempDirPrefix: tempDirPrefix)
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

        let events = eventsAfterTurnFrame(try await collectEvents(session, prompt: "turn 6"))

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        // The summary text is flash's own canned response — proof flash,
        // not the session's own model, actually produced it.
        #expect(result.summary == "FLASH-SUMMARY")
        // The result names the flash slot's model as the summary's writer —
        // the signal task ^59fd9rt adds, so a consumer can judge the summary
        // against the model that wrote it.
        #expect(result.summarizerModel == "org/flash-a")

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

        let events = eventsAfterTurnFrame(try await collectEvents(session, prompt: "turn 6"))

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        // The summary text is the session's own canned response, not flash's —
        // proof the own-model tier, not flash, produced it. Stored word for
        // word: the canned answer fits the folded span's byte budget, so the
        // stage stores it exactly as the model wrote it (task ^xx02yn6).
        let summary = try #require(result.summary)
        #expect(summary == Self.cannedText)
        // The result names the session's own model, not the flash slot's —
        // the fallback tier is just as visible as the preferred one.
        #expect(result.summarizerModel == "org/std-a")

        // The triggering turn's own work still ran normally afterward.
        #expect(events.contains(.textDelta(Self.cannedText)))
    }

    // MARK: - Opt-out regression

    @Test("a session vended with no budget never auto-compacts, regardless of measured fill")
    @MainActor
    func noBudgetMeansNoAutoCompaction() async throws {
        let (session, _, _) = try await Self.makeTriggeredSession(budget: nil)
        #expect(await session.contextFill == 0.9)

        let events = try await collectEvents(session, prompt: "turn 6")

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

        let events = eventsAfterTurnFrame(try await collectEvents(forked, prompt: "fork turn"))

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
                        Transcript.Response(segments: [.text(Transcript.TextSegment(content: responseText))])),
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
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: responseText))])))
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
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recorder = InMemoryRecorder()
        let seedEntries = ScriptedOverflowBackend.seedEntries(turnCount: 6, responseText: Self.cannedText)
        let standardContainer = OverflowLLMContainer(
            responseText: "recovered", seedEntries: seedEntries, overflowsRemaining: 1)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: RouterTestFixtures.stubDimension)
        let router = RouterTestFixtures.makeRouter(cacheDir: dir, recorder: recorder, loader: loader)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(context: 100_000), reporting: ResolutionProgress())

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
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recorder = InMemoryRecorder()
        let seedEntries = ScriptedOverflowBackend.seedEntries(turnCount: 6, responseText: Self.cannedText)
        // Overflows on every call this test could plausibly make (initial +
        // the one retry) — proving the session gives up after one retry
        // rather than looping.
        let standardContainer = OverflowLLMContainer(
            responseText: "unreachable", seedEntries: seedEntries, overflowsRemaining: 1_000)
        let flashContainer = ConfiguredLLMContainer(responseText: "FLASH-SUMMARY")
        let loader = PerSlotModelLoader(standard: standardContainer, flash: flashContainer, dimension: RouterTestFixtures.stubDimension)
        let router = RouterTestFixtures.makeRouter(cacheDir: dir, recorder: recorder, loader: loader)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(context: 100_000), reporting: ResolutionProgress())

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

    // MARK: - Hard ceiling: deterministic fail-fast before a doomed generate (task g2hcm36)

    @Test(
        "a session whose budget sets a hard ceiling fails fast with ContextBudgetError before the doomed generate call even runs, then recovers via the same fold-harder-and-retry-once path as a context overflow, reporting live per-attempt contextFill"
    )
    @MainActor
    func hardCeilingFailsFastThenRecoversWithLivePerAttemptFill() async throws {
        // `trigger: 2.0` never fires proactively (fill tops out at 0.9 across
        // this suite) — isolating the hard-ceiling pre-check in
        // `runTurnAttempt` from the trigger-driven proactive fold in `runTurn`.
        // Built by overriding ``fixedBudget`` rather than restating its
        // numbers: the recovery this test asserts depends on the retry's own
        // fold *actually shrinking* the transcript, which is exactly what
        // `fixedBudget`'s derived below-the-recency-floor target guarantees.
        var hardCeilingBudget = Self.fixedBudget
        hardCeilingBudget.trigger = 2.0
        hardCeilingBudget.hardCeiling = 0.85
        let (session, standard, _) = try await Self.makeTriggeredSession(budget: hardCeilingBudget)
        #expect(await session.contextFill == 0.9)

        // A small increment for the triggering turn's own (retried) generate
        // call, distinct from the warm-up turns' escalating increments, so
        // the retry's own measured fill is unambiguously lower than the
        // blocked attempt's stale 0.9 — proving the meter actually moved
        // mid-turn rather than only once the whole turn finished.
        standard.lastBackend?.usageIncrement = (input: 1_000, output: 0)

        let events = eventsAfterTurnFrame(try await collectEvents(session, prompt: "turn 6"))

        guard case .turnEnded(let blockedUsage) = events.first else {
            Issue.record(
                "expected the first event to be turnEnded (the pre-flight-blocked attempt), got \(String(describing: events.first))"
            )
            return
        }
        // The blocked attempt never touched the backend: a genuine zero
        // delta, and contextFill left exactly as it was before this turn
        // (never reset to a meaningless zero).
        #expect(blockedUsage == TokenUsage(tokensIn: 0, tokensOut: 0, contextFill: 0.9))

        guard case .compaction(let result) = events[1] else {
            Issue.record("expected the second event to be .compaction, got \(String(describing: events[1]))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))

        // The blocked attempt's own generate call never ran: no textDelta
        // appears before the fold.
        #expect(!events[0..<2].contains { if case .textDelta = $0 { return true }; return false })
        #expect(events.contains(.textDelta(Self.cannedText)))

        guard case .turnEnded(let retryUsage) = events.last else {
            Issue.record("expected the last event to be turnEnded (the recovered retry), got \(String(describing: events.last))")
            return
        }
        // contextFill's own denominator is always the session's resolved
        // `contextTokens` (100_000, per `makeTriggeredSession`'s own
        // `router.resolve(profile: RouterTestFixtures.profile(context: 100_000)...)`) —
        // never `budget.limit`, which only sizes the compaction target.
        #expect(retryUsage == TokenUsage(tokensIn: 1_000, tokensOut: 0, contextFill: 1_000.0 / 100_000.0))
        // The context meter genuinely moved *during* this one logical turn,
        // not only once it fully finished (compaction_plan.md §1.7, task g2hcm36).
        #expect(retryUsage.contextFill < blockedUsage.contextFill)
    }

    @Test(
        "a hard ceiling still not met after the one retry (an unfoldable transcript: the fold was a genuine no-op) surfaces ContextBudgetError.hardCeilingExceeded, never looping"
    )
    @MainActor
    func hardCeilingStillExceededAfterRetrySurfacesError() async throws {
        // `limit: 100_000` matches the session's own resolved `contextTokens`
        // (`makeTriggeredSession`'s `router.resolve(profile: RouterTestFixtures.profile(context: 100_000)...)`),
        // and `target: 0.9` sits far above the tiny warm-up transcript's real
        // size, so every fold this budget drives — including the reactive
        // retry's own lowered-target fold — is a genuine no-op (nothing to
        // shrink): `contextFill` never actually moves once measured. That
        // deterministically guarantees the retry's own pre-check sees the
        // exact same fill that tripped the first attempt, rather than
        // depending on precise fold-sizing math to land above some
        // threshold. `hardCeiling: 0.85` reuses the same window as
        // `hardCeilingFailsFastThenRecoversWithLivePerAttemptFill` — above
        // every warm-up turn's own pre-turn fill (≤ 0.75) but at/below the
        // triggering turn's own 0.9.
        let hardCeilingBudget = TokenBudget(limit: 100_000, trigger: 2.0, target: 0.9, hardCeiling: 0.85)
        let (session, standard, _) = try await Self.makeTriggeredSession(budget: hardCeilingBudget)
        #expect(await session.contextFill == 0.9)
        let callsBeforeTriggeringTurn = standard.lastBackend?.callCount

        var collected: [SessionEvent] = []
        var caught: Error?
        do {
            for try await event in await session.streamEvents(to: "turn 6", maxTokens: nil) {
                collected.append(event)
            }
        } catch {
            caught = error
        }

        guard case .hardCeilingExceeded(let fill, let ceiling) = caught as? ContextBudgetError else {
            Issue.record("expected ContextBudgetError.hardCeilingExceeded, got \(String(describing: caught))")
            return
        }
        #expect(fill == 0.9)
        #expect(ceiling == 0.85)

        let compactionEvents = collected.filter { if case .compaction = $0 { return true }; return false }
        // Exactly one fold ever ran (the one retry) before giving up — a
        // second fold would mean looping.
        #expect(compactionEvents.count == 1)
        guard case .compaction(let result) = compactionEvents.first else {
            Issue.record("expected a .compaction event")
            return
        }
        // It was a genuine no-op — exactly why the retry hit the same
        // ceiling again instead of recovering.
        #expect(result.stagesApplied.isEmpty)

        // Both attempts were blocked pre-flight; the original backend was
        // never asked to generate again after the warm-up turns.
        #expect(standard.lastBackend?.callCount == callsBeforeTriggeringTurn)
    }

    // MARK: - Tools + budget composition (task 4ce0a1k)

    @Test("EchoTool returns its input verbatim; FailingTool always throws")
    func sampleToolsBehaveAsDocumented() async throws {
        let echo = EchoTool()
        let echoed = try await echo.call(arguments: SampleToolArguments(text: "hello"))
        #expect(echoed == "hello")

        let failing = FailingTool()
        await #expect(throws: FailingTool.Failure.boom) {
            try await failing.call(arguments: SampleToolArguments(text: "x"))
        }
    }

    @Test(
        "a session vended with both tools and a budget threads the tools to the session's own tool list and still proactively folds exactly like one with no tools"
    )
    @MainActor
    func toolsAndBudgetComposeWithoutInterference() async throws {
        let echo = EchoTool()
        let failing = FailingTool()
        let (session, _, _) = try await Self.makeTriggeredSession(budget: Self.fixedBudget, tools: [echo, failing])

        guard let actor = session as? RoutedSessionActor else {
            Issue.record("expected a RoutedSessionActor")
            return
        }
        // Every String-output tool arrives wrapped in the mount layer;
        // peel it to reach the threaded originals.
        let innerTools = actor.tools.compactMap { ($0 as? RunToCompletionRunner<SampleToolArguments>)?.wrapped }
        #expect(innerTools.contains { $0 is EchoTool })
        #expect(innerTools.contains { $0 is FailingTool })

        // contextFill is 0.9 (>= the 0.8 trigger) after the warm-up turns —
        // identical to the no-tools case above; the presence of tools must
        // not change fold-triggering behavior at all.
        #expect(await session.contextFill == 0.9)

        let events = eventsAfterTurnFrame(try await collectEvents(session, prompt: "turn 6"))

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied.contains("Summarization"))
        #expect(events.contains(.textDelta(Self.cannedText)))
    }

    // MARK: - The session's own Summarization reaches the automatic fold

    /// The recency window the fold-tuning test below vends its session's
    /// ``Summarization`` with: half the stage's own default, so two turns the
    /// default window would have kept land in the span flash actually reads.
    private static let narrowedRecentTurns = Summarization().keepRecentTurns / 2

    @Test(
        "an automatic fold summarizes with the Summarization the session was vended with, not the stage's defaults: a narrowed keepRecentTurns puts turns the default window keeps out into the span flash reads"
    )
    @MainActor
    func autoFoldSummarizesWithTheSessionsOwnKeepRecentTurns() async throws {
        let (narrowedSession, _, narrowedFlash) = try await Self.makeTriggeredSession(
            budget: Self.fixedBudget,
            summarization: Summarization(keepRecentTurns: Self.narrowedRecentTurns))
        let (unturnedSession, _, unturnedFlash) = try await Self.makeTriggeredSession(budget: Self.fixedBudget)

        // No caller-side compact() in either arm: the triggering turn folds on
        // its own, which is the fold this test exists for — it is the one no
        // caller could pass a Summarization to.
        let narrowedEvents = try await collectEvents(narrowedSession, prompt: "turn \(Self.turnCount)")
        let unturnedEvents = try await collectEvents(unturnedSession, prompt: "turn \(Self.turnCount)")
        #expect(narrowedEvents.contains { if case .compaction = $0 { return true }; return false })
        #expect(unturnedEvents.contains { if case .compaction = $0 { return true }; return false })

        // The newest turn only the narrowed window folds: inside the default
        // window, so a fold running at the stage's defaults never reads it.
        let narrowedWindowOnly = renderedLineOfNewestFoldedTurn(
            turnCount: Self.turnCount, keepRecentTurns: Self.narrowedRecentTurns)
        #expect(narrowedFlash.generationLog.calls.contains { $0.prompt.contains(narrowedWindowOnly) })
        #expect(!unturnedFlash.generationLog.calls.contains { $0.prompt.contains(narrowedWindowOnly) })

        // Both folds really did read a span — the newest turn the *default*
        // window folds is in each — so the assertions above separate two live
        // folds rather than a fold from a no-op.
        let foldedEitherWay = renderedLineOfNewestFoldedTurn(
            turnCount: Self.turnCount, keepRecentTurns: Summarization().keepRecentTurns)
        #expect(narrowedFlash.generationLog.calls.contains { $0.prompt.contains(foldedEitherWay) })
        #expect(unturnedFlash.generationLog.calls.contains { $0.prompt.contains(foldedEitherWay) })
    }
}
