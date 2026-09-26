import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The fixtures of ``AnswerCancellationTests``: the stub profile and
/// router, the compaction budgets and the warm-up session, and the helpers
/// that suspend an answer inside a tool call and wait for its unwind.
extension AnswerCancellationTests {
    // MARK: - Fixtures

    static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": 8192,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    static let stubDimension = 8

    /// The scale a compaction's target size is measured against — ``Compactor`` compacts
    /// down to `limit * target` tokens — set far above anything
    /// ``cancellationSurvivesIntoTheOverflowRetry(route:)`` puts in a transcript,
    /// so even the *reactive* compaction finds nothing to shed and lands as a no-op,
    /// leaving the retry itself as the only thing left to observe.
    ///
    /// Not a stand-in for the session's context window: that is the profile's
    /// resolved ``SlotResolution/contextTokens``, which is what
    /// ``RoutedSession/contextFill`` divides by. A budget's `limit` never enters
    /// a fill measurement, so raising this does not move fill.
    static let noOpCompactionScale = 100_000

    /// A `trigger` above `1.0` — a fraction measured fill does not reach — so no
    /// *proactive* compaction ever runs and the reactive compact-and-retry-once path is
    /// the only compaction in play.
    ///
    /// Belt and braces rather than the operative reason:
    /// ``cancellationSurvivesIntoTheOverflowRetry(route:)`` sends a single
    /// prompt, so nothing has been metered yet when the proactive gate reads
    /// ``RoutedSession/contextFill`` and it sees `0` — under even the `0.80`
    /// default. Pinning the trigger above `1.0` keeps the proactive compaction out of
    /// the way should that test ever grow an answer that does meter usage.
    static let unreachableFillTrigger = 2.0

    /// The fraction of ``noOpCompactionScale`` a compaction aims to come down to, spelled out
    /// rather than left to the `0.50` default so the compaction's target size is
    /// visible at the call site.
    ///
    /// Inert either way: at this scale the target — and the overflow retry's
    /// target, which is never above it — stays far above the transcript.
    static let inertCompactionTarget = 0.25

    /// The auto-compaction opt-in ``cancellationSurvivesIntoTheOverflowRetry(route:)``
    /// vends its session with: enough to switch on the reactive
    /// compact-and-retry-once recovery, and nothing else.
    static let unreachableTriggerBudget = TokenBudget(
        limit: noOpCompactionScale,
        trigger: unreachableFillTrigger,
        target: inertCompactionTarget
    )

    // MARK: - Compaction fixtures

    /// The compaction prompt a compaction test vends its session with, so the mid-answer
    /// hook can tell a compaction's own **summarizer** call from an ordinary submission: the
    /// prompt ``Summarization`` sends is the rendered span being condensed, a line of
    /// three dashes, then this text. A match on the dashes and this text fires for
    /// exactly the compaction's model calls and for nothing else (see ``isSummarizerCall``).
    static let compactionSummarizerPrompt = CompactionPrompt(
        name: "answer-cancellation-compaction-suspend",
        text: "SUSPEND-INSIDE-THE-COMPACTION"
    )

    /// Whether the model call carrying `prompt` is a compaction's own summarizer call.
    static let isSummarizerCall: @Sendable (String) -> Bool = {
        $0.contains("\n\n---\n\n\(compactionSummarizerPrompt.text)\n\n")
    }

    /// Matches a compaction's **first** summarizer call and no later one — what every test
    /// that suspends inside a compaction suspends on.
    ///
    /// Single-shot deliberately. A compaction test suspends in that first call and cancels
    /// there; a regression that then let the compaction degrade to another tier would suspend
    /// a *second* call on a semaphore nothing is left to signal, hanging the suite
    /// instead of failing the assertion that caught it. Letting later calls run
    /// straight through makes that same regression a fast, ordinary failure —
    /// the answer finishes and the `CancellationError` expectation fails.
    ///
    /// - Returns: A predicate that is `true` exactly once, for the first summarizer
    ///   call it sees.
    static func firstSummarizerCall() -> @Sendable (String) -> Bool {
        let callsSeen = Mutex(0)
        return { prompt in
            guard isSummarizerCall(prompt) else { return false }
            return callsSeen.withLock { seen -> Bool in
                seen += 1
                return seen == 1
            }
        }
    }

    /// How many warm-up answers ``makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)`` drives
    /// before the answer that compacts, so the compaction has a conversation to
    /// summarize and therefore a real summarizer call to make.
    static let compactionWarmUpAnswerCount = 6

    /// The measured fill a compaction test's budget compacts at — ``TokenBudget``'s own
    /// default trigger, spelled out because these budgets are built by
    /// ``compactionBudget(targetTokens:)`` rather than by ``TokenBudget/init(limit:trigger:target:hardCeiling:toolOutputLimit:)``.
    static let compactionFillTrigger = 0.8

    /// The share of the session's own resolved context window the last warm-up
    /// answer measures, above ``compactionFillTrigger`` so the *next* answer compacts.
    static let compactionTriggeringFillFraction = 0.9

    /// The fraction of a compaction budget's `limit` its target sits at — an arbitrary
    /// choice ``compactionBudget(targetTokens:)`` inverts, present only so a wanted
    /// target size can be stated directly instead of back-computed at each call
    /// site.
    static let compactionTargetFraction = 0.25

    /// A budget that compacts to `targetTokens`, stated as the size it lands on
    /// rather than as ``TokenBudget``'s own `limit`/`target` pair —
    /// ``Compactor`` compacts to `limit * target`, so this inverts that.
    ///
    /// - Parameter targetTokens: The size, in tokens, the compaction should aim for.
    /// - Returns: A budget with that target size and ``compactionFillTrigger``'s trigger.
    static func compactionBudget(targetTokens: Int) -> TokenBudget {
        TokenBudget(
            limit: Int(Double(targetTokens) / compactionTargetFraction),
            trigger: compactionFillTrigger,
            target: compactionTargetFraction
        )
    }

    /// The prompt ``cancellingTheReactiveCompactionStopsTheRetry()`` drives its answer with,
    /// named because its mid-answer hook has to tell the own model call of that
    /// answer (which must overflow) from the compaction's summarizer call (which
    /// must suspend).
    static let overflowingCompactionPrompt = "overflows-then-compacts"

    /// The prompt ``makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)``'s
    /// warm-up answer `index` sends.
    static func warmUpPrompt(_ index: Int) -> String { "warm-\(index)" }

    /// The exact transcript entries those warm-up answers leave behind, computed
    /// without running a session: ``HookedSessionBackend`` appends one `.prompt`
    /// carrying the own prompt of the answer and one `.response` carrying
    /// `"ok-"` plus it, so both budgets below can be sized up front from this
    /// alone.
    static func warmUpEntries() -> [Transcript.Entry] {
        (0..<compactionWarmUpAnswerCount).flatMap { index -> [Transcript.Entry] in
            let prompt = warmUpPrompt(index)
            return [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
                .response(
                    Transcript.Response(
                        segments: [.text(Transcript.TextSegment(content: "ok-\(prompt)"))])),
            ]
        }
    }

    /// A budget whose target is under the warm-up transcript: the default
    /// target of ``TokenBudget`` over a limit of the warm-up transcript's size.
    /// The compaction then makes its one summarizer call, which is the call
    /// these tests cancel inside.
    static var summarizingCompactionBudget: TokenBudget {
        compactionBudget(targetTokens: TokenBudget(limit: characterCount(of: warmUpEntries())).targetTokens)
    }

    /// A session whose measured ``RoutedSession/contextFill`` has already cleared
    /// `budget`'s trigger, holding ``compactionWarmUpAnswerCount`` answers of real content —
    /// so the *next* answer on it compacts proactively, before running any model work of
    /// its own.
    ///
    /// - Parameters:
    ///   - fixture: The fixture to vend the session from.
    ///   - budget: The auto-compaction opt-in to vend it with, sized by
    ///     ``summarizingCompactionBudget``.
    ///   - metersTriggeringFill: Whether the last warm-up answer measures enough usage
    ///     to clear `budget`'s trigger. `true` (the default) for a test about the
    ///     *proactive* compaction; `false` for one about the **reactive**
    ///     compact-and-retry-once compact, where a proactive compaction firing first would
    ///     compact the transcript out from under it — with no measured usage, fill stays
    ///     at `0` and the proactive gate never fires.
    /// - Returns: The session, warmed up, and over its trigger unless metering was
    ///   declined.
    static func makeCompactionTriggeredSession(
        _ fixture: Fixture,
        budget: TokenBudget,
        metersTriggeringFill: Bool = true
    ) async throws -> any RoutedSession {
        let session = fixture.model.makeSession(budget: budget, compactionPrompt: compactionSummarizerPrompt)
        let backend = try #require(fixture.container.lastVendedBackend)
        let contextTokens = try #require(session as? RoutedSessionActor).contextTokens

        for index in 0..<(compactionWarmUpAnswerCount - 1) {
            _ = try await session.respond(to: warmUpPrompt(index))
        }
        // Only the last warm-up answer measures, and its delta between the snapshots
        // taken either side of it is what `contextFill` then reports — see
        // ``HookedSessionBackend/startMetering(inputTokensPerSubmission:)`` for why not
        // from the first answer.
        if metersTriggeringFill {
            backend.startMetering(
                inputTokensPerSubmission: Int(Double(contextTokens) * compactionTriggeringFillFraction))
        }
        _ = try await session.respond(to: warmUpPrompt(compactionWarmUpAnswerCount - 1))

        #expect((await session.contextFill >= budget.trigger) == metersTriggeringFill)
        return session
    }

    static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AnswerCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Whether one further ordinary answer on `session` runs to completion,
    /// observed through `observer` under a bounded spin rather than by awaiting
    /// the answer.
    ///
    /// The indirection is the point: a regression that strands the pump
    /// blocks every later message on that session forever, so awaiting such an
    /// answer directly would hang the whole suite instead of failing an
    /// assertion in the test that caught it.
    static func followUpAnswerCompletes(
        on session: any RoutedSession,
        observer: AnswerObserver,
        prompt: String = "after"
    ) async -> Bool {
        let task = Task { try await session.respond(to: prompt) }
        await BoundedWait.spin(until: { await observer.exited.contains(prompt) })
        guard await observer.exited.contains(prompt) else {
            // Never admitted to the model at all — its message was stranded. The
            // suite must not await it.
            task.cancel()
            return false
        }
        return (try? await task.value) != nil
    }

    /// The events one further answer on `session` produced, or `nil` when that
    /// answer never reached the model.
    ///
    /// ``followUpAnswerCompletes(on:observer:prompt:)`` for a test that has to *see*
    /// what the next answer did — its own ``SessionEvent/compaction(_:)``, say — and
    /// bounded by the same spin for the same reason: a regression that stranded
    /// the pump would hang the suite rather than fail the test that caught it.
    ///
    /// Unlike that method, this one *does* await the task on its give-up path, and
    /// the difference is deliberate — do not "fix" the two to match. This task
    /// consumes an `AsyncThrowingStream`, whose `next()` is cancellation-aware and
    /// ends, so cancelling it always completes it. ``followUpAnswerCompletes(on:observer:prompt:)``
    /// wraps a bare `respond(to:)` whose answer a stranded pump never gives, so
    /// awaiting it there would hang exactly when the helper exists to avoid
    /// hanging.
    ///
    /// - Parameters:
    ///   - session: The session to run one more answer on.
    ///   - observer: The observer that the model call of that answer reports to.
    ///   - prompt: The prompt of that answer.
    /// - Returns: The events of the answer in order, or `nil` when it never ran or failed.
    static func followUpAnswerEvents(
        on session: any RoutedSession,
        observer: AnswerObserver,
        prompt: String = "after"
    ) async -> [SessionEvent]? {
        let delivered = DeliveredEvents()
        let task = Task {
            for try await event in await session.streamEvents(to: prompt) {
                await delivered.append(event)
            }
        }
        await BoundedWait.spin(until: { await observer.exited.contains(prompt) })
        guard await observer.exited.contains(prompt) else {
            task.cancel()
            _ = try? await task.value
            return nil
        }
        guard (try? await task.value) != nil else { return nil }
        return await delivered.events
    }

    /// The one live model handle every session in a test is vended from, plus the
    /// container, observer, and hook wired behind it.
    struct Fixture {
        let observer: AnswerObserver
        let hook: AnswerHook
        let recorder: InMemoryRecorder

        /// The container every session in a test is vended from, for the one
        /// question the observer cannot answer — see
        /// ``HookedLLMContainer/lastVendedBackend``.
        let container: HookedLLMContainer

        /// Retained for the fixture's whole lifetime: a ``RoutedLLM`` holds its
        /// owning profile weakly, so dropping this would make `makeSession` trap.
        let profile: LanguageModelProfile

        /// The one resident model every session in a test is vended from.
        var model: RoutedLLM { profile.standard }
    }

    /// Resolves a stub profile and returns its `standard` handle plus the shared
    /// hook/observer/recorder wired into every backend it will vend.
    ///
    /// - Parameters:
    ///   - cacheDir: The router's cache/recording root.
    ///   - appendsPromptBeforeToolCall: Whether the vended backends append the
    ///     `.prompt` entry of a submission before running the mid-answer tool
    ///     hook — the switch between a cancelled submission that durably
    ///     delivered its drained outbox events and one that delivered nothing.
    ///   - pool: The resident-model pool. Defaults to a fresh pool, so parallel suites never share residents.
    static func makeFixture(
        cacheDir: URL,
        appendsPromptBeforeToolCall: Bool = true,
        pool: ModelPool = ModelPool()
    ) async throws -> Fixture {
        let hook = AnswerHook()
        let observer = AnswerObserver()
        let container = HookedLLMContainer(
            hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall)
        let recorder = InMemoryRecorder()
        let router = Router(
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension),
            pool: pool
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return Fixture(observer: observer, hook: hook, recorder: recorder, container: container, profile: profile)
    }

    /// Installs a mid-answer hook that suspends the answer named `prompt` inside a tool
    /// call which *observes* cancellation: it suspends on a semaphore released by
    /// its own cancellation handler, then re-checks cancellation and reports what
    /// it saw — the shape a real MCP tool awaiting a reply has, rather than a poll
    /// of `Task.isCancelled`.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - suspendsOn: Whether the model call carrying this prompt is the one to
    ///     suspend. Every call it rejects runs straight through, so one hook serves a
    ///     whole test: the prompt of an ordinary answer (see
    ///     ``suspendInsideCancellationAwareTool(_:prompt:insideTool:)``) or
    ///     a compaction's own summarizer call (see ``isSummarizerCall``).
    ///   - insideTool: Signalled once the answer is provably suspended inside the
    ///     tool call, so a test cancels at a known point rather than racing to
    ///     get there.
    /// - Returns: The event the tool signals once it has observed the cancellation,
    ///   so a test waits on that moment instead of polling for it.
    static func suspendInsideCancellationAwareTool(
        _ fixture: Fixture,
        suspendingOn suspendsOn: @escaping @Sendable (String) -> Bool,
        insideTool: AsyncSemaphore
    ) -> AwaitedEvent {
        let observer = fixture.observer
        let suspended = AsyncSemaphore(value: 0)
        let sawCancellation = AwaitedEvent()
        let suspend: @Sendable () async throws -> Void = {
            await withTaskCancellationHandler {
                insideTool.signal()
                await suspended.wait()
            } onCancel: {
                suspended.signal()
            }
            do {
                try Task.checkCancellation()
            } catch {
                await observer.noteToolSawCancellation()
                // Signalled after the observer has been written and never before, so
                // a test the event resumes always finds
                // ``AnswerObserver/toolSawCancellation`` already set.
                sawCancellation.signal()
                throw error
            }
        }
        fixture.hook.midAnswer = { submittedPrompt in
            guard suspendsOn(submittedPrompt) else { return }
            try await suspend()
        }
        return sawCancellation
    }

    /// Suspends the answer whose own prompt is `prompt`, matched as a **suffix**
    /// of what the backend actually receives: a submission that drained outbox
    /// events is handed those events as a preamble followed by its own prompt
    /// (see ``RoutedSessionActor/composedPrompt(pendingEvents:prompt:)``), so an
    /// equality check would silently never fire for exactly the submissions the
    /// outbox tests suspend.
    ///
    /// The common case, and a thin spelling of
    /// ``suspendInsideCancellationAwareTool(_:suspendingOn:insideTool:)`` — a
    /// compaction test suspends on that one's predicate instead, since a summarizer call is
    /// identified by its *prefix*.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - prompt: The own prompt text of the answer to suspend on.
    ///   - insideTool: Signalled once the answer is provably suspended inside
    ///     the tool call.
    /// - Returns: The event the tool signals once it has observed the cancellation.
    static func suspendInsideCancellationAwareTool(
        _ fixture: Fixture,
        prompt: String,
        insideTool: AsyncSemaphore
    ) -> AwaitedEvent {
        suspendInsideCancellationAwareTool(
            fixture, suspendingOn: { $0.hasSuffix(prompt) }, insideTool: insideTool)
    }

    /// Waits for a cancellation the test has just requested to reach the tool
    /// suspended by ``suspendInsideCancellationAwareTool(_:prompt:insideTool:)``,
    /// then asserts the answer unwound with `CancellationError`.
    ///
    /// The event first, and never a bare `await answerTask.value`: that tool resumes
    /// only when cancellation reaches it, and it resumes out of
    /// ``AsyncSemaphore/wait()``, which ignores cancellation by design. So a
    /// regression in propagation leaves the answer suspended where no time limit can
    /// reach it, and awaiting the answer straight away would hang the whole run instead
    /// of failing the test that caught the fault. The event is a wait the suite's
    /// `.timeLimit` *can* break, so the fault ends this test instead. Past the event
    /// the tool has already thrown and the answer is already unwinding, which is what
    /// makes the `await` below safe.
    ///
    /// - Parameters:
    ///   - answerTask: The task awaiting the cancelled answer, whatever it returns.
    ///   - sawCancellation: The event ``suspendInsideCancellationAwareTool(_:prompt:insideTool:)``
    ///     returned for that tool.
    /// - Throws: ``EventNeverArrived`` when the suite's `.timeLimit` ended the wait
    ///   because the cancellation never reached the tool at all.
    static func awaitCancelledUnwind<Value: Sendable>(
        _ answerTask: Task<Value, Error>,
        sawCancellation: AwaitedEvent
    ) async throws {
        try await sawCancellation.wait()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
    }
}
