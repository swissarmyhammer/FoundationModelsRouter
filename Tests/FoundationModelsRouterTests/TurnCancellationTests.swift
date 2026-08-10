import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/cancelCurrentTurn()``: cancelling the turn already
/// **in flight**, as opposed to ``RoutedSession/cancel(id:)``'s queue-side
/// withdrawal of a prompt that has not been dispatched yet.
///
/// The chain this closes is `ACP session/cancel` -> Router -> MCP
/// `notifications/cancelled`: `FoundationModelsMCP` already turns Swift task
/// cancellation into the protocol-level notification, and a client stop already
/// reaches Router — so the only missing link was Router's own ability to cancel
/// the `Task` that owns the model call a tool runs inside. These tests prove
/// cancellation reaches *inside* the model call (the regression the work exists
/// for), that a cancelled turn is recorded exactly like any other failed turn
/// rather than half-written, that gate accounting survives it, and that the
/// documented no-op cases really are no-ops.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, exactly as in
/// ``HumanWaitGateTests``. Determinism comes from ``AsyncSemaphore``
/// observability and bounded cooperative spins rather than from sleeps.
@Suite("In-flight turn cancellation reaches the model call, and the tools inside it")
struct TurnCancellationTests {
    /// The two routes a turn in flight can be cancelled by, so a test can assert
    /// the same behavior of both instead of duplicating itself per route.
    enum CancellationRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// ``RoutedSession/cancelCurrentTurn()`` — Router's own primitive.
        case routerAPI

        /// The turn's caller cancelling its own enclosing `Task` — the propagation
        /// Router had before it had a primitive of its own.
        case callerTask

        var testDescription: String {
            switch self {
            case .routerAPI: "cancelCurrentTurn()"
            case .callerTask: "the caller's own Task"
            }
        }
    }

    /// Failures a test's own stand-in tool raises — to mark a path that must never
    /// be taken, or to stand in for a fault the model itself would raise.
    private enum ProbeError: Error, Equatable {
        /// The overflow retry re-entered the model even though the turn had
        /// already been cancelled.
        case modelReenteredAfterCancellation

        /// A summarizer call failed for a reason of its own, with nothing about it
        /// cancellation-shaped.
        case summarizerFailed
    }

    // MARK: - Turn observability

    /// Records which turns entered and left the model and whether a tool
    /// running inside the model call ever observed cancellation, so
    /// propagation past `body` is asserted rather than inferred.
    private actor TurnObserver {
        private(set) var entered: [String] = []
        private(set) var exited: [String] = []
        private(set) var toolSawCancellation = false

        func enter(_ prompt: String) {
            entered.append(prompt)
        }

        func exit(_ prompt: String) {
            exited.append(prompt)
        }

        func noteToolSawCancellation() {
            toolSawCancellation = true
        }
    }

    /// Collects the events a streaming turn delivered before it failed.
    ///
    /// Outside the task draining the stream deliberately: that task throws when the
    /// stream finishes with an error, taking any locally accumulated array with it,
    /// and what a cancelled stream *did* hand its consumer first is exactly what
    /// this suite needs to assert.
    private actor DeliveredEvents {
        private(set) var events: [SessionEvent] = []

        func append(_ event: SessionEvent) {
            events.append(event)
        }
    }

    /// The mid-generation closure a test installs, standing in for a tool the
    /// SDK invokes *inside* the model call. It is handed the turn's prompt so
    /// one hook can serve several sessions, parking only the turn a test means
    /// to park.
    ///
    /// A plain mutable class rather than an actor because
    /// ``HookedSessionBackend/respond(to:maxTokens:)`` reads it from whatever
    /// isolation the turn runs on: `@unchecked Sendable` is safe because
    /// ``midTurn`` is written exactly once, on the single `@MainActor` test task,
    /// before any turn is started, and only read afterwards.
    private final class TurnHook: @unchecked Sendable {
        var midTurn: (@Sendable (String) async throws -> Void)?
    }

    // MARK: - Stub container + backend

    /// A ``LanguageModelSessionBackend`` that runs ``TurnHook/midTurn`` in the
    /// middle of `respond`, standing in for a long-running MCP tool call the
    /// SDK invokes from inside the model call.
    ///
    /// ``appendsPromptBeforeToolCall`` decides whether this turn's `.prompt`
    /// entry is already in the transcript when the tool runs — which is exactly
    /// what decides a cancelled turn's outbox rule: a turn whose prompt was
    /// durably appended really did deliver its drained events to the model, and
    /// one that appended nothing never did.
    ///
    /// Properly `Sendable` rather than `@unchecked`, unlike ``StubSessionBackend``,
    /// because on this backend the transcript really is shared: the streaming path
    /// produces from a task of its own, and a turn cancelled mid-stream stops
    /// consuming (and goes on to read ``transcriptEntries()`` for its diff) while
    /// that producer is still live. Whether the two actually overlap depends on
    /// what the installed hook does about cancellation, which is no basis for a
    /// data-race argument — so ``entries`` is behind a ``Mutex`` and the question
    /// does not arise.
    private final class HookedSessionBackend: LanguageModelSessionBackend {
        private let hook: TurnHook
        private let observer: TurnObserver
        private let appendsPromptBeforeToolCall: Bool

        /// This backend's synthetic transcript.
        private let transcript: Mutex<[Transcript.Entry]>

        /// This backend's synthetic transcript, as of this read.
        var entries: [Transcript.Entry] { transcript.withLock { $0 } }

        /// What ``usageTokenCounts()`` reports: how many input tokens each
        /// completed turn adds to a running total, and that total so far.
        private struct Metering {
            /// The input tokens one completed turn adds, or `nil` for a backend
            /// that reports no usage at all.
            var inputTokensPerTurn: Int?

            /// Every metered turn's input tokens so far.
            var totalInputTokens = 0
        }

        /// This backend's measured usage — behind a lock for the same reason
        /// ``transcript`` is, and mutable because a fold fixture starts metering
        /// between two turns.
        private let metering: Mutex<Metering>

        init(
            hook: TurnHook,
            observer: TurnObserver,
            appendsPromptBeforeToolCall: Bool,
            entries: [Transcript.Entry] = [],
            inputTokensPerTurn: Int? = nil
        ) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
            self.transcript = Mutex(entries)
            self.metering = Mutex(Metering(inputTokensPerTurn: inputTokensPerTurn))
        }

        /// The input tokens each completed turn adds to this backend's measured
        /// usage, as of this read — carried over to every backend derived from
        /// this one, so a fold that swaps the session's backend does not silently
        /// stop it measuring.
        var inputTokensPerTurn: Int? { metering.withLock { $0.inputTokensPerTurn } }

        /// Starts reporting measured usage: `inputTokensPerTurn` input tokens for
        /// every turn completed from here on.
        ///
        /// A fold fixture starts metering only for its *last* warm-up turn: a
        /// session measuring usage from its first turn would cross its budget's
        /// trigger with almost nothing in its transcript, and a fold with no old
        /// span left to summarize never makes a summarizer call at all.
        ///
        /// - Parameter inputTokensPerTurn: The input tokens each completed turn
        ///   adds to the running total.
        func startMetering(inputTokensPerTurn: Int) {
            metering.withLock { $0.inputTokensPerTurn = inputTokensPerTurn }
        }

        /// Adds one completed turn's measured input tokens to the running total,
        /// so that turn's own delta — the difference between the snapshots the
        /// session takes either side of it — is exactly
        /// ``Metering/inputTokensPerTurn``.
        private func meterOneTurn() {
            metering.withLock { state in
                guard let perTurn = state.inputTokensPerTurn else { return }
                state.totalInputTokens += perTurn
            }
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if appendsPromptBeforeToolCall {
                appendPrompt(prompt)
            }
            await observer.enter(prompt)
            if let midTurn = hook.midTurn {
                do {
                    try await midTurn(prompt)
                } catch {
                    await observer.exit(prompt)
                    throw error
                }
            }
            if !appendsPromptBeforeToolCall {
                appendPrompt(prompt)
            }
            let responseText = "ok-\(prompt)"
            appendResponse(responseText)
            meterOneTurn()
            await observer.exit(prompt)
            return responseText
        }

        private func appendPrompt(_ prompt: String) {
            transcript.withLock {
                $0.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            }
        }

        private func appendResponse(_ responseText: String) {
            transcript.withLock {
                $0.append(
                    .response(
                        Transcript.Response(
                            assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))]))
                )
            }
        }

        /// The chunk a streaming turn yields *before* running the tool hook — what
        /// a consumer has already received by the time a cancellation lands.
        static let firstStreamedChunk = "ok-"

        /// Streams the response in two chunks with ``TurnHook/midTurn`` run
        /// between them, so a streaming turn parks inside a tool call exactly like
        /// a whole-response one — and a test can tell that the consumer kept the
        /// chunk it had already been handed when the cancellation landed.
        ///
        /// The transcript entries land in the same places relative to the tool call
        /// as ``respond(to:maxTokens:)`` puts them, so
        /// ``appendsPromptBeforeToolCall`` means the same thing on both paths. They
        /// are written from this stream's own producer task, which can outlive the
        /// turn's consumption of the stream — see ``transcript``, which is why they
        /// are written under a lock.
        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            if appendsPromptBeforeToolCall {
                appendPrompt(prompt)
            }
            let hook = hook
            let observer = observer
            return AsyncThrowingStream { continuation in
                let task = Task {
                    await observer.enter(prompt)
                    continuation.yield(Self.firstStreamedChunk)
                    if let midTurn = hook.midTurn {
                        do {
                            try await midTurn(prompt)
                        } catch {
                            await observer.exit(prompt)
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    if !self.appendsPromptBeforeToolCall {
                        self.appendPrompt(prompt)
                    }
                    let responseText = "ok-\(prompt)"
                    self.appendResponse(responseText)
                    self.meterOneTurn()
                    continuation.yield(String(responseText.dropFirst(Self.firstStreamedChunk.count)))
                    await observer.exit(prompt)
                    continuation.finish()
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
            }
        }


        /// Not exercised by this suite — guided decoding is orthogonal to
        /// cancellation, and has its own suite.
        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try grammar.validateForXGrammar()
            return "guided-ok"
        }

        func transcriptEntries() -> [Transcript.Entry] {
            entries
        }

        /// This backend's measured usage, or `nil` until ``startMetering(inputTokensPerTurn:)``
        /// is called — the default, and what every test here but the fold ones
        /// wants: a session with no measured usage has no measured
        /// ``RoutedSession/contextFill``, so no proactive fold can trigger.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            metering.withLock { state -> (input: Int, output: Int)? in
                guard state.inputTokensPerTurn != nil else { return nil }
                return (input: state.totalInputTokens, output: 0)
            }
        }

        func makeFork() -> any LanguageModelSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall,
                entries: entries, inputTokensPerTurn: inputTokensPerTurn)
        }

        /// Honors the replacement transcript rather than taking
        /// ``LanguageModelSessionBackend``'s `makeFork()`-based default, which
        /// keeps this backend's own entries instead.
        ///
        /// A fold swaps the session's backend for one seeded with the *folded*
        /// transcript and sets `persistedEntryCount` from that same transcript, so
        /// a fixture that ignored the replacement would leave the two disagreeing
        /// and have the next turn's diff record entries no real session would. The
        /// running usage total deliberately starts over, the way a genuinely new
        /// session over the same model does; the per-turn measurement carries on.
        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall,
                entries: Array(transcript), inputTokensPerTurn: inputTokensPerTurn)
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer.
    ///
    /// Almost every test here observes turns through the shared ``TurnObserver``
    /// and the recorder rather than by reaching for a particular session's
    /// backend; the exception is ``lastVendedBackend``, which the fold fixture
    /// needs (see its doc), so the vended backend is retained behind a lock.
    private final class HookedLLMContainer: LoadedLLMContainer {
        private let hook: TurnHook
        private let observer: TurnObserver
        private let appendsPromptBeforeToolCall: Bool

        /// The most recently vended backend.
        private let lastVended = Mutex<HookedSessionBackend?>(nil)

        init(hook: TurnHook, observer: TurnObserver, appendsPromptBeforeToolCall: Bool) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
        }

        /// The backend this container vended most recently — the one the session
        /// built right after it is driving.
        ///
        /// The only way to reach it: `RoutedSessionActor.backend` is `private` and
        /// ``RoutedSession`` exposes no accessor for it, and
        /// ``makeFoldTriggeredSession(_:budget:metersTriggeringFill:)`` has to start metering on the
        /// session's own backend to move its measured ``RoutedSession/contextFill``.
        var lastVendedBackend: HookedSessionBackend? { lastVended.withLock { $0 } }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: [])
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: Array(transcript))
        }

        private func makeHookedBackend(entries: [Transcript.Entry]) -> HookedSessionBackend {
            let backend = HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall, entries: entries)
            lastVended.withLock { $0 = backend }
            return backend
        }
    }

    /// A stub embedder container — never exercised here, present only so the
    /// profile resolves. No MLX.
    private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

    private struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    private struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` returning the identical, test-supplied container for
    /// every generation slot — so every session in a test shares one model, and
    /// therefore one generation gate. No download, no GPU.
    private struct StubModelLoader: ModelLoader {
        let container: HookedLLMContainer
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

    // MARK: - Fixtures

    private static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    private static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    private static let profile = ProfileDefinition(
        name: "coding",
        description: "test profile",
        standard: ["org/std-a"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"]
    )

    private static let stubDimension = 8

    /// The scale a fold's target size is measured against — ``Compactor`` folds
    /// down to `limit * target` tokens — set far above anything
    /// ``cancellationSurvivesIntoTheOverflowRetry(route:)`` puts in a transcript,
    /// so even the *reactive* fold finds nothing to shed and lands as a no-op,
    /// leaving the retry itself as the only thing left to observe.
    ///
    /// Not a stand-in for the session's context window: that is the profile's
    /// resolved ``SlotResolution/contextTokens``, which is what
    /// ``RoutedSession/contextFill`` divides by. A budget's `limit` never enters
    /// a fill measurement, so raising this does not move fill.
    private static let noOpFoldScale = 100_000

    /// A `trigger` above `1.0` — a fraction measured fill does not reach — so no
    /// *proactive* fold ever runs and the reactive compact-and-retry-once path is
    /// the only fold in play.
    ///
    /// Belt and braces rather than the operative reason:
    /// ``cancellationSurvivesIntoTheOverflowRetry(route:)`` sends a single
    /// prompt, so nothing has been metered yet when the proactive gate reads
    /// ``RoutedSession/contextFill`` and it sees `0` — under even the `0.80`
    /// default. Pinning the trigger above `1.0` keeps the proactive fold out of
    /// the way should that test ever grow a turn that does meter usage.
    private static let unreachableFillTrigger = 2.0

    /// The fraction of ``noOpFoldScale`` a fold aims to come down to, spelled out
    /// rather than left to the `0.50` default so the fold's target size is
    /// visible at the call site.
    ///
    /// Inert either way: at this scale the target — and the halved one the
    /// overflow retry folds harder to — stays far above the transcript.
    private static let inertFoldTarget = 0.25

    /// The auto-compaction opt-in ``cancellationSurvivesIntoTheOverflowRetry(route:)``
    /// vends its session with: enough to turn on the reactive
    /// compact-and-retry-once recovery, and nothing else.
    private static let unreachableTriggerBudget = TokenBudget(
        limit: noOpFoldScale,
        trigger: unreachableFillTrigger,
        target: inertFoldTarget
    )

    // MARK: - Fold fixtures

    /// The compaction prompt a fold test vends its session with, so the mid-turn
    /// hook can tell a fold's own **summarizer** call from an ordinary turn: the
    /// prompt ``Summarization`` sends is this text followed by the rendered span
    /// being condensed, so a prefix match on it fires for exactly the fold's model
    /// calls and for nothing else (see ``isSummarizerCall``).
    private static let foldSummarizerPrompt = CompactionPrompt(
        name: "turn-cancellation-fold-park",
        text: "PARK-INSIDE-THE-FOLD"
    )

    /// Whether the model call carrying `prompt` is a fold's own summarizer call.
    private static let isSummarizerCall: @Sendable (String) -> Bool = {
        $0.hasPrefix(foldSummarizerPrompt.text)
    }

    /// Matches a fold's **first** summarizer call and no later one — what every test
    /// that parks inside a fold parks on.
    ///
    /// Single-shot deliberately. A fold test parks in that first call and cancels
    /// there; a regression that then let the fold degrade to another tier would park
    /// a *second* call on a semaphore nothing is left to signal, hanging the suite
    /// instead of failing the assertion that caught it. Letting later calls run
    /// straight through turns that same regression into a fast, ordinary failure —
    /// the turn finishes and the `CancellationError` expectation fails.
    ///
    /// - Returns: A predicate that is `true` exactly once, for the first summarizer
    ///   call it sees.
    private static func firstSummarizerCall() -> @Sendable (String) -> Bool {
        let callsSeen = Mutex(0)
        return { prompt in
            guard isSummarizerCall(prompt) else { return false }
            return callsSeen.withLock { seen -> Bool in
                seen += 1
                return seen == 1
            }
        }
    }

    /// How many of the newest turns every compaction stage leaves untouched —
    /// ``ToolOutputElision``/``TurnTruncation``/``Summarization``'s shared
    /// `keepRecentTurns` default, which a fold test's warm-up must exceed for a
    /// fold to have any old span left to summarize.
    private static let foldRecencyWindowTurns = 4

    /// How many warm-up turns ``makeFoldTriggeredSession(_:budget:metersTriggeringFill:)`` drives
    /// before the turn that folds — past ``foldRecencyWindowTurns``, so the fold
    /// has an old span to condense and therefore a real summarizer call to make.
    private static let foldWarmUpTurnCount = 6

    /// The measured fill a fold test's budget folds at — ``TokenBudget``'s own
    /// default trigger, spelled out because these budgets are built by
    /// ``foldBudget(targetTokens:)`` rather than by ``TokenBudget/init(limit:trigger:target:hardCeiling:toolOutputLimit:)``.
    private static let foldFillTrigger = 0.8

    /// The share of the session's own resolved context window the last warm-up
    /// turn measures, above ``foldFillTrigger`` so the *next* turn folds.
    private static let foldTriggeringFillFraction = 0.9

    /// The fraction of a fold budget's `limit` its target sits at — an arbitrary
    /// choice ``foldBudget(targetTokens:)`` inverts, present only so a wanted
    /// target size can be stated directly instead of back-computed at each call
    /// site.
    private static let foldTargetFraction = 0.25

    /// A budget that folds to `targetTokens`, stated as the size it lands on
    /// rather than as ``TokenBudget``'s own `limit`/`target` pair —
    /// ``Compactor`` folds to `limit * target`, so this inverts that.
    ///
    /// - Parameter targetTokens: The estimated token size the fold should aim for.
    /// - Returns: A budget with that target size and ``foldFillTrigger``'s trigger.
    private static func foldBudget(targetTokens: Int) -> TokenBudget {
        TokenBudget(
            limit: Int(Double(targetTokens) / foldTargetFraction),
            trigger: foldFillTrigger,
            target: foldTargetFraction
        )
    }

    /// The prompt ``cancellingTheReactiveFoldStopsTheRetry()`` drives its turn with,
    /// named because its mid-turn hook has to tell that turn's own model call (which
    /// must overflow) from the fold's summarizer call (which must park).
    private static let overflowingFoldPrompt = "overflows-then-folds"

    /// The prompt ``makeFoldTriggeredSession(_:budget:metersTriggeringFill:)``'s
    /// warm-up turn `index` sends.
    private static func warmUpPrompt(_ index: Int) -> String { "warm-\(index)" }

    /// The exact transcript entries those warm-up turns leave behind, computed
    /// without running a session: ``HookedSessionBackend`` appends one `.prompt`
    /// carrying the turn's own prompt and one `.response` carrying `"ok-"` plus
    /// it, so both budgets below can be sized up front from this alone.
    private static func warmUpEntries() -> [Transcript.Entry] {
        (0..<foldWarmUpTurnCount).flatMap { index -> [Transcript.Entry] in
            let prompt = warmUpPrompt(index)
            return [
                .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
                .response(
                    Transcript.Response(
                        assetIDs: [], segments: [.text(Transcript.TextSegment(content: "ok-\(prompt)"))])),
            ]
        }
    }

    /// The estimated size of just ``warmUpEntries()``'s recency window — the floor
    /// the deterministic stages bottom out at, since ``TurnTruncation`` drops the
    /// older turns outright and leaves this untouched.
    private static func warmUpRecencyWindowEstimate() -> Int {
        let (header, turns) = TranscriptTurns.split(warmUpEntries())
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: foldRecencyWindowTurns)
        return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
    }

    /// A budget the deterministic stages **cannot** satisfy: its target is half the
    /// warm-up transcript's recency-window floor, so ``ToolOutputElision`` (nothing
    /// to elide — these turns make no tool calls) and ``TurnTruncation`` (which
    /// bottoms out at that floor) both leave it over target, and the fold goes on
    /// to call the summarizer. That call is the model-assisted stage these tests
    /// cancel inside.
    private static var summarizingFoldBudget: TokenBudget {
        foldBudget(targetTokens: warmUpRecencyWindowEstimate() / 2)
    }

    /// A budget the deterministic stages **can** satisfy: its target sits midway
    /// between the recency-window floor ``TurnTruncation`` lands on and the whole
    /// warm-up transcript, so the fold finishes deterministically and never makes a
    /// model call at all.
    private static var deterministicFoldBudget: TokenBudget {
        let whole = Compactor.estimatedTokenCount(of: Transcript(entries: warmUpEntries()))
        return foldBudget(targetTokens: (warmUpRecencyWindowEstimate() + whole) / 2)
    }

    /// A session whose measured ``RoutedSession/contextFill`` has already cleared
    /// `budget`'s trigger, holding ``foldWarmUpTurnCount`` turns of real content —
    /// so the *next* turn on it folds proactively, before running any model work of
    /// its own.
    ///
    /// - Parameters:
    ///   - fixture: The fixture to vend the session from.
    ///   - budget: The auto-compaction opt-in to vend it with, sized by
    ///     ``summarizingFoldBudget`` or ``deterministicFoldBudget``.
    ///   - metersTriggeringFill: Whether the last warm-up turn measures enough usage
    ///     to clear `budget`'s trigger. `true` (the default) for a test about the
    ///     *proactive* fold; `false` for one about the **reactive**
    ///     compact-and-retry-once fold, where a proactive fold firing first would
    ///     fold the transcript out from under it — with no measured usage, fill stays
    ///     at `0` and the proactive gate never fires.
    /// - Returns: The session, warmed up, and over its trigger unless metering was
    ///   declined.
    private static func makeFoldTriggeredSession(
        _ fixture: Fixture,
        budget: TokenBudget,
        metersTriggeringFill: Bool = true
    ) async throws -> any RoutedSession {
        let session = fixture.model.makeSession(budget: budget, compactionPrompt: foldSummarizerPrompt)
        let backend = try #require(fixture.container.lastVendedBackend)
        let contextTokens = try #require(session as? RoutedSessionActor).contextTokens

        for index in 0..<(foldWarmUpTurnCount - 1) {
            _ = try await session.respond(to: warmUpPrompt(index))
        }
        // Only the last warm-up turn measures, and its delta between the snapshots
        // taken either side of it is what `contextFill` then reports — see
        // ``HookedSessionBackend/startMetering(inputTokensPerTurn:)`` for why not
        // from the first turn.
        if metersTriggeringFill {
            backend.startMetering(inputTokensPerTurn: Int(Double(contextTokens) * foldTriggeringFillFraction))
        }
        _ = try await session.respond(to: warmUpPrompt(foldWarmUpTurnCount - 1))

        #expect((await session.contextFill >= budget.trigger) == metersTriggeringFill)
        return session
    }

    private static func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TurnCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// How many cooperative yields ``spin(until:)`` gives a condition before it
    /// gives up.
    ///
    /// A timeout measured in scheduler hops rather than wall clock: high enough
    /// that a state change these tests genuinely order behind a handful of task
    /// suspensions always lands, low enough that a condition which never holds
    /// gives up in well under a second instead of hanging the suite.
    private static let spinYieldLimit = 100_000

    /// Spins cooperatively until `condition` holds or ``spinYieldLimit`` yields
    /// elapse, so a scheduler-ordered state change is observed without a sleep —
    /// and a condition that never holds fails an assertion rather than hanging
    /// the suite.
    private static func spin(until condition: @Sendable () async -> Bool) async {
        for _ in 0..<spinYieldLimit {
            if await condition() { return }
            await Task.yield()
        }
    }

    /// Whether one further ordinary turn on `session` runs to completion,
    /// observed through `observer` under a bounded spin rather than by awaiting
    /// the turn.
    ///
    /// The indirection is the point: a regression that strands a generation permit
    /// parks every later turn over that model forever, so awaiting such a turn
    /// directly would hang the whole suite instead of failing an assertion in the
    /// test that caught it.
    private static func followUpTurnCompletes(
        on session: any RoutedSession,
        observer: TurnObserver,
        prompt: String = "after"
    ) async -> Bool {
        let task = Task { try await session.respond(to: prompt) }
        await spin(until: { await observer.exited.contains(prompt) })
        guard await observer.exited.contains(prompt) else {
            // Never admitted to the model at all — parked on a gate. Cancelling
            // will not unpark it (``AsyncSemaphore/wait()`` ignores cancellation
            // by design), but the suite must not await it either.
            task.cancel()
            return false
        }
        return (try? await task.value) != nil
    }

    /// The events one further turn on `session` produced, or `nil` when that turn
    /// never reached the model.
    ///
    /// ``followUpTurnCompletes(on:observer:prompt:)`` for a test that has to *see*
    /// what the next turn did — its own ``SessionEvent/compaction(_:)``, say — and
    /// bounded by the same spin for the same reason: a regression that stranded a
    /// generation permit would hang the suite rather than fail the test that caught
    /// it.
    ///
    /// Unlike that method, this one *does* await the task on its give-up path, and
    /// the difference is deliberate — do not "fix" the two to match. This task
    /// consumes an `AsyncThrowingStream`, whose `next()` is cancellation-aware and
    /// ends, so cancelling it always completes it. ``followUpTurnCompletes(on:observer:prompt:)``
    /// wraps a bare `respond(to:)` that can be parked in ``AsyncSemaphore/wait()``,
    /// which ignores cancellation by design, so awaiting it there would hang exactly
    /// when the helper exists to avoid hanging.
    ///
    /// - Parameters:
    ///   - session: The session to run one more turn on.
    ///   - observer: The observer that turn's model call reports to.
    ///   - prompt: That turn's prompt.
    /// - Returns: The turn's events in order, or `nil` when it never ran or failed.
    private static func followUpTurnEvents(
        on session: any RoutedSession,
        observer: TurnObserver,
        prompt: String = "after"
    ) async -> [SessionEvent]? {
        let delivered = DeliveredEvents()
        let task = Task {
            for try await event in await session.streamEvents(to: prompt) {
                await delivered.append(event)
            }
        }
        await spin(until: { await observer.exited.contains(prompt) })
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
    private struct Fixture {
        let observer: TurnObserver
        let hook: TurnHook
        let recorder: InMemoryRecorder

        /// The container every session in a test is vended from, for the one
        /// question the observer cannot answer — see
        /// ``HookedLLMContainer/lastVendedBackend``.
        let container: HookedLLMContainer

        /// Retained for the fixture's whole lifetime: a ``RoutedLLM`` holds its
        /// owning profile weakly, so dropping this would make `makeSession` trap.
        let profile: LanguageModelProfile

        /// The one resident model every session in a test is vended from, and so
        /// the one generation gate they all share.
        var model: RoutedLLM { profile.standard }
    }

    /// Resolves a stub profile and returns its `standard` handle plus the shared
    /// hook/observer/recorder wired into every backend it will vend.
    ///
    /// - Parameters:
    ///   - cacheDir: The router's cache/recording root.
    ///   - appendsPromptBeforeToolCall: Whether the vended backends append this
    ///     turn's `.prompt` entry before running the mid-turn tool hook — the
    ///     switch between a cancelled turn that durably delivered its drained
    ///     outbox events and one that delivered nothing.
    private static func makeFixture(
        cacheDir: URL,
        appendsPromptBeforeToolCall: Bool = true
    ) async throws -> Fixture {
        let hook = TurnHook()
        let observer = TurnObserver()
        let container = HookedLLMContainer(
            hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall)
        let recorder = InMemoryRecorder()
        let router = Router(
            maxConcurrentForks: 4,
            cacheDir: cacheDir,
            recorder: recorder,
            probe: StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
            metadataSource: StubMetadataSource(raw: rawMetadata),
            loader: StubModelLoader(container: container, dimension: stubDimension)
        )
        let profile = try await router.resolve(profile: Self.profile, reporting: ResolutionProgress())
        return Fixture(observer: observer, hook: hook, recorder: recorder, container: container, profile: profile)
    }

    /// Installs a mid-turn hook that parks the turn named `prompt` inside a tool
    /// call which *observes* cancellation: it suspends on a semaphore released by
    /// its own cancellation handler, then re-checks cancellation and reports what
    /// it saw — the shape a real MCP tool awaiting a reply has, rather than a poll
    /// of `Task.isCancelled`.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - parksOn: Whether the model call carrying this prompt is the one to
    ///     park. Every call it rejects runs straight through, so one hook serves a
    ///     whole test: an ordinary turn's prompt (see
    ///     ``parkInsideCancellationAwareTool(_:prompt:insideTool:humanWait:)``) or
    ///     a fold's own summarizer call (see ``isSummarizerCall``).
    ///   - insideTool: Signalled once the turn is provably suspended inside the
    ///     tool call, so a test cancels at a known point rather than racing to
    ///     get there.
    ///   - humanWait: The session to park inside ``RoutedSession/awaitingUser(_:)``
    ///     on — the tool-awaiting-a-person shape, which hands the generation permit
    ///     back for the duration — or `nil` to park directly in the tool call. The
    ///     wait itself is identical either way, which is the point of the
    ///     parameter: the gate-accounting test must exercise the same park as the
    ///     others, not a copy of it.
    /// - Returns: The semaphore the tool parks on, so
    ///   ``awaitCancelledUnwind(_:observer:parked:)`` can force it open when a
    ///   regression stops cancellation reaching the tool at all.
    private static func parkInsideCancellationAwareTool(
        _ fixture: Fixture,
        parkingOn parksOn: @escaping @Sendable (String) -> Bool,
        insideTool: AsyncSemaphore,
        humanWait: (any RoutedSession)? = nil
    ) -> AsyncSemaphore {
        let observer = fixture.observer
        let parked = AsyncSemaphore(value: 0)
        let park: @Sendable () async throws -> Void = {
            await withTaskCancellationHandler {
                insideTool.signal()
                await parked.wait()
            } onCancel: {
                parked.signal()
            }
            do {
                try Task.checkCancellation()
            } catch {
                await observer.noteToolSawCancellation()
                throw error
            }
        }
        fixture.hook.midTurn = { turnPrompt in
            guard parksOn(turnPrompt) else { return }
            guard let humanWait else {
                try await park()
                return
            }
            try await humanWait.awaitingUser(park)
        }
        return parked
    }

    /// Parks the turn whose own prompt is `prompt`, matched as a **suffix** of
    /// what the backend actually receives: a turn that drained outbox events is
    /// handed those events as a preamble followed by its own prompt (see
    /// ``RoutedSessionActor/composedPrompt(pendingEvents:prompt:)``), so an
    /// equality check would silently never fire for exactly the turns the outbox
    /// tests park.
    ///
    /// The common case, and a thin spelling of
    /// ``parkInsideCancellationAwareTool(_:parkingOn:insideTool:humanWait:)`` — a
    /// fold test parks on that one's predicate instead, since a summarizer call is
    /// identified by its *prefix*.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - prompt: The turn's own prompt text to park on.
    ///   - insideTool: Signalled once the turn is provably suspended inside the
    ///     tool call.
    ///   - humanWait: The session to park inside ``RoutedSession/awaitingUser(_:)``
    ///     on, or `nil` to park directly in the tool call.
    /// - Returns: The semaphore the tool parks on.
    private static func parkInsideCancellationAwareTool(
        _ fixture: Fixture,
        prompt: String,
        insideTool: AsyncSemaphore,
        humanWait: (any RoutedSession)? = nil
    ) -> AsyncSemaphore {
        parkInsideCancellationAwareTool(
            fixture, parkingOn: { $0.hasSuffix(prompt) }, insideTool: insideTool, humanWait: humanWait)
    }

    /// Waits for a cancellation the test has just requested to reach the tool
    /// parked by ``parkInsideCancellationAwareTool(_:prompt:insideTool:humanWait:)``,
    /// then asserts the turn unwound with `CancellationError`.
    ///
    /// Deliberately not a bare `await turnTask.value`: that tool unparks only when
    /// cancellation actually reaches it, so a regression in propagation would leave
    /// the turn suspended forever and hang the whole suite — this target sets no
    /// `.timeLimit` trait — instead of failing the test that caught it. On timeout
    /// this reports the issue and then unwinds the turn by force (open the park,
    /// cancel the caller's task) so no later assertion or test inherits a stuck
    /// session.
    ///
    /// - Parameters:
    ///   - turnTask: The task awaiting the cancelled turn, whatever it returns.
    ///   - observer: The observer the parked tool reports its cancellation to.
    ///   - parked: The semaphore ``parkInsideCancellationAwareTool(_:prompt:insideTool:humanWait:)``
    ///     returned for that tool.
    private static func awaitCancelledUnwind<Value: Sendable>(
        _ turnTask: Task<Value, Error>,
        observer: TurnObserver,
        parked: AsyncSemaphore
    ) async {
        guard await awaitCancellationReachingTheTool(turnTask, observer: observer, parked: parked) else { return }
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }
    }

    /// Waits for a cancellation the test has just requested to reach the parked tool,
    /// reporting an issue and force-unwinding the turn if it never does.
    ///
    /// ``awaitCancelledUnwind(_:observer:parked:)`` minus its final assertion, for the
    /// one caller that cannot make it: a consumer which cancelled *its own* task
    /// mid-`AsyncThrowingStream` sees that stream **finish** rather than throw, so
    /// there is no `CancellationError` for it to catch even though the turn behind the
    /// stream was cancelled (see
    /// ``cancelledProactiveFoldReportsNoCompaction(route:)``). Factored out rather than
    /// duplicated, so both spellings share one bound and one diagnostic.
    ///
    /// - Parameters:
    ///   - turnTask: The task awaiting the cancelled turn, whatever it returns.
    ///   - observer: The observer the parked tool reports its cancellation to.
    ///   - parked: The semaphore ``parkInsideCancellationAwareTool(_:prompt:insideTool:humanWait:)``
    ///     returned for that tool.
    /// - Returns: Whether the cancellation reached the tool. `false` means an issue was
    ///   already recorded and the turn already unwound by force, so the caller should
    ///   assert nothing further.
    private static func awaitCancellationReachingTheTool<Value: Sendable>(
        _ turnTask: Task<Value, Error>,
        observer: TurnObserver,
        parked: AsyncSemaphore
    ) async -> Bool {
        await spin(until: { await observer.toolSawCancellation })
        guard await observer.toolSawCancellation else {
            Issue.record("cancellation never reached the tool call running inside the model call")
            parked.signal()
            turnTask.cancel()
            _ = try? await turnTask.value
            return false
        }
        return true
    }

    // MARK: - The regression: a stop must reach a running tool call

    @Test("cancelCurrentTurn cancels the in-flight turn's model call, and the tool running inside it sees CancellationError")
    @MainActor
    func cancellingAnInFlightTurnReachesTheToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let turnTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        #expect(await session.cancelCurrentTurn() == .requested)

        // The whole point: the tool call *inside* the model call observes the
        // cancellation, and the turn then unwinds with it.
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)
        #expect(await fixture.observer.toolSawCancellation)
    }

    @Test("cancelling the caller's own Task still reaches the tool call, exactly as before")
    @MainActor
    func cancellingTheCallersOwnTaskStillReachesTheToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "caller-cancels", insideTool: insideTool)

        let turnTask = Task { try await session.respond(to: "caller-cancels") }
        await insideTool.wait()

        // Router runs the model call in a task of its own so it can cancel it
        // from outside; that must not cost the caller the propagation plan.md
        // always promised from cancelling its own enclosing `Task`.
        turnTask.cancel()

        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)
        #expect(await fixture.observer.toolSawCancellation)

        // Recorded the same way as a turn cancelled through `cancelCurrentTurn()`,
        // even though this cancellation unwinds the task the recording itself runs
        // in: nothing on the recording path observes cancellation, so a
        // caller-cancelled turn is no more half-written than any other failed one.
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == nil)
    }

    // MARK: - Recording

    @Test("a cancelled turn is recorded exactly like any other failed turn, and the session keeps working")
    @MainActor
    func cancelledTurnLeavesAConsistentTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let turnTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // Whatever the SDK durably appended before the cancellation landed (the
        // turn's `.prompt` entry), plus exactly one close — the synthetic
        // bodyless `.response` every failed turn gets, never two and never none.
        let cancelledTurnEvents = await fixture.recorder.events
        #expect(cancelledTurnEvents.map(\.kind) == [.session, .prompt, .response])
        let close = try #require(cancelledTurnEvents.last)
        #expect(close.text == nil)
        #expect(close.ms != nil)

        // Nothing was left half-written: an ordinary turn on the same session
        // records its own whole prompt/response pair straight after. Run through
        // `followUpTurnCompletes` rather than awaited directly, so a regression that
        // stranded one of this turn's permits fails here instead of parking the
        // follow-up turn — and the suite with it — forever.
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        let afterEvents = await fixture.recorder.events
        #expect(afterEvents.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(afterEvents.last?.text == "ok-after")
    }

    // MARK: - Gate accounting

    @Test("cancelling a turn parked in awaitingUser leaves both gates balanced and blocks no other session")
    @MainActor
    func cancellingATurnParkedInAwaitingUserKeepsGatesBalanced() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let generationGate = fixture.model.generationGate
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()
        let turnLockA = try #require(sessionA as? RoutedSessionActor).turnLock

        // The turn parks on a person from inside `awaitingUser`, so its
        // generation permit has been lent back to the model when the
        // cancellation arrives — the interaction between in-flight cancellation
        // and the split gate.
        let insideWait = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, prompt: "cancel-in-wait", insideTool: insideWait, humanWait: sessionA)

        let turnTask = Task { try await sessionA.respond(to: "cancel-in-wait") }
        await insideWait.wait()
        #expect(generationGate.availablePermits == 1)

        #expect(await sessionA.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // Exactly one permit is back — not two (a permit minted by a release the
        // cancelled wait never balanced) and not none (one stranded by it).
        #expect(generationGate.availablePermits == 1)
        #expect(generationGate.waiterCount == 0)
        #expect(turnLockA.availablePermits == 1)
        #expect(turnLockA.waiterCount == 0)

        // The behavioral proof: another session over the same model still
        // generates, and so does the cancelled one.
        #expect(await Self.followUpTurnCompletes(on: sessionB, observer: fixture.observer, prompt: "other-session"))
        #expect(await Self.followUpTurnCompletes(on: sessionA, observer: fixture.observer))
        #expect(generationGate.availablePermits == 1)
    }

    // MARK: - The outbox rule

    @Test("a cancelled turn that durably delivered its drained events records them rather than re-queueing them")
    @MainActor
    func cancelledTurnKeepsDeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends the turn's `.prompt` entry before the tool runs,
        // so the composed preamble carrying the drained event really did reach
        // the model before the cancellation landed.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: true)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(posted)

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let turnTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // Delivered, so not re-queued: the drained event rode the cancelled
        // turn's recorded prompt and is not staged again.
        let pending = await session.outbox.pending()
        #expect(pending.events.isEmpty)
        let promptEvent = try #require(await fixture.recorder.events.first { $0.kind == .prompt })
        #expect(promptEvent.text?.contains("run command") == true)
    }

    @Test("a cancelled turn that delivered nothing re-queues its drained events instead of destroying them")
    @MainActor
    func cancelledTurnRequeuesUndeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends nothing before the tool runs, so a cancellation
        // there leaves the turn with no `.prompt` partial for the drained event
        // to attach to — it was never durably delivered.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: false)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(posted)

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let turnTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }

    // MARK: - The streaming and queue-dispatch entry points

    @Test("cancelCurrentTurn finishes a streamEvents turn with CancellationError, leaving the consumer what it already received")
    @MainActor
    func cancellingAStreamingTurnFinishesTheStreamWithCancellationError() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "stream-cancel", insideTool: insideTool)

        // The stream is drained into `delivered` as it arrives, so what the consumer
        // had already been handed survives the error the stream finishes with.
        let delivered = DeliveredEvents()
        let turnTask = Task { () throws -> Int in
            for try await event in await session.streamEvents(to: "stream-cancel") {
                await delivered.append(event)
            }
            return await delivered.events.count
        }
        await insideTool.wait()

        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // Everything the turn produced before the cancellation is still the
        // consumer's — a cancelled stream is truncated, not retracted.
        #expect(await delivered.events.contains(.textDelta(HookedSessionBackend.firstStreamedChunk)))
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
    }

    @Test("cancelling a dispatched queued prompt's turn unwinds it and consumes the prompt, which the drain had already committed")
    @MainActor
    func cancellingADispatchedTurnConsumesTheQueuedPrompt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let queued = await session.enqueue(prompt: "dispatch-cancel")
        let insideTool = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(fixture, prompt: "dispatch-cancel", insideTool: insideTool)

        let turnTask = Task { try await session.dispatchNextPrompt() }
        await insideTool.wait()

        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // `drainForDispatch()` is the commit point, and a cancellation does not roll
        // it back: the prompt is spent, and its id reports what it reported the
        // moment it was drained.
        #expect(await session.pendingPrompts().isEmpty)
        #expect(await session.cancel(id: queued) == .alreadySent)
    }

    // MARK: - No-ops and best-effort honesty

    @Test("cancelling twice, and cancelling after the turn has finished, are safe no-ops")
    @MainActor
    func cancellingTwiceAndAfterCompletionIsASafeNoOp() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Before any turn: nothing to cancel.
        #expect(await session.cancelCurrentTurn() == .noTurnInFlight)

        // This tool unwinds only when the test says so, rather than out of its own
        // cancellation handler: a tool that unwinds the moment cancellation lands
        // lets the whole turn finish between the two calls below, which makes
        // "twice against one in-flight turn" a race rather than a test. It still
        // ends in a real cancellation — it checks for one once released.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midTurn = { prompt in
            guard prompt.hasSuffix("cancel-me") else { return }
            insideTool.signal()
            await release.wait()
            do {
                try Task.checkCancellation()
            } catch {
                await observer.noteToolSawCancellation()
                throw error
            }
        }

        let turnTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        // Twice while the same turn is provably still in flight: the second call
        // requests what was already requested and changes nothing.
        #expect(await session.cancelCurrentTurn() == .requested)
        #expect(await session.cancelCurrentTurn() == .requested)

        release.signal()
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }
        #expect(await fixture.observer.toolSawCancellation)

        // After it has finished: no turn to cancel, and the request left behind
        // cannot bleed into the next turn — which is a claim about permits too, so
        // the follow-up turn goes through `followUpTurnCompletes` rather than being
        // awaited directly.
        #expect(await session.cancelCurrentTurn() == .noTurnInFlight)
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
        #expect(await session.cancelCurrentTurn() == .noTurnInFlight)
    }

    @Test("a turn whose model work ignores cancellation still completes — Router stopped listening, the work did not stop")
    @MainActor
    func cancellationIsBestEffortWhenTheWorkIgnoresIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation — the local stand-in for an MCP
        // server that keeps working through an advisory
        // `notifications/cancelled`.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt == "stubborn" else { return }
            insideTool.signal()
            await release.wait()
        }

        let turnTask = Task { try await session.respond(to: "stubborn") }
        await insideTool.wait()
        #expect(await session.cancelCurrentTurn() == .requested)

        // Nothing Router can do makes it stop, so the turn runs to completion and
        // is recorded as the whole turn it was.
        release.signal()
        #expect(try await turnTask.value == "ok-stubborn")
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == "ok-stubborn")
    }

    @Test("a turn cancelled while queued behind another never reaches the model at all")
    @MainActor
    func cancellingAQueuedTurnNeverReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()
        let turnLock = try #require(session as? RoutedSessionActor).turnLock

        // The first turn holds the turn lock and parks inside the model without
        // checking cancellation, so the second turn is provably queued rather than
        // racing to start.
        let insideFirstTurn = AsyncSemaphore(value: 0)
        let releaseFirstTurn = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt.hasSuffix("holds-the-lock") else { return }
            insideFirstTurn.signal()
            await releaseFirstTurn.wait()
        }

        let firstTask = Task { try await session.respond(to: "holds-the-lock") }
        await insideFirstTurn.wait()

        let queuedTask = Task { try await session.respond(to: "queued-and-cancelled") }
        await Self.spin(until: { turnLock.waiterCount == 1 })
        #expect(turnLock.waiterCount == 1)

        // Cancelled while parked on a gate. Gate acquisition ignores cancellation by
        // design, so this turn still takes its place in line — what it does once it
        // gets there is the question.
        queuedTask.cancel()
        releaseFirstTurn.signal()
        #expect(try await firstTask.value == "ok-holds-the-lock")

        // It throws rather than generating: with nothing under way to observe the
        // cancellation, the model is never called for this turn at all — which is
        // the one case where the turn does *not* return a response it never saw
        // cancelled (see ``RoutedSession/cancelCurrentTurn()``).
        await #expect(throws: CancellationError.self) {
            try await queuedTask.value
        }
        #expect(await fixture.observer.entered == ["holds-the-lock"])

        // Recorded like any other failed turn even so — the first turn's whole
        // prompt/response pair, then the cancelled turn's lone bodyless close.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response, .response])
        #expect(events.last?.text == nil)
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
    }

    @Test("abandoning a stream mid-turn cancels the turn behind it, which is then recorded as cancelled rather than completed")
    @MainActor
    func abandoningAStreamRecordsTheTurnAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation, so what is asserted below is the
        // *turn's* own outcome rather than the tool's cooperation.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midTurn = { prompt in
            guard prompt.hasSuffix("abandon-stream") else { return }
            insideTool.signal()
            await release.wait()
        }

        // Take one fragment and walk away — a consumer that stops listening.
        var delivered: [String] = []
        for try await chunk in await session.streamResponse(to: "abandon-stream") {
            delivered.append(chunk)
            break
        }
        #expect(delivered == [HookedSessionBackend.firstStreamedChunk])

        // Waiting for the tool to park first keeps the assertion below deterministic:
        // the turn's diff must run while the backend still has no `.response` entry
        // for this turn, which is exactly the state a cut-short turn is in.
        await insideTool.wait()
        await Self.spin(until: { await fixture.recorder.events.count == 3 })

        // Not "a turn that finished with a short response": a cancelled turn, with
        // the same lone bodyless close every other failed turn gets.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == nil)

        // Let the abandoned producer drain rather than leaving it parked for the
        // rest of the suite.
        release.signal()
        await Self.spin(until: { await fixture.observer.exited.contains("abandon-stream") })
        #expect(await fixture.observer.exited.contains("abandon-stream"))
    }

    // MARK: - A cancellation is not forgotten between a turn's attempts

    @Test(
        "a cancellation landing during a failed attempt stops the overflow retry from re-running the model",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellationSurvivesIntoTheOverflowRetry(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // A budget makes this session recover from context overflow by folding
        // harder and retrying once — and that retry is the window where a turn
        // holds the turn lock with no model call outstanding, so a cancellation
        // arriving in it has no task to cancel and must be remembered instead.
        let session = fixture.model.makeSession(budget: Self.unreachableTriggerBudget)

        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midTurn = { prompt in
            guard prompt.hasSuffix("overflow-then-cancel") else { return }
            // A second call means the retry re-ran the model after the turn was
            // already cancelled — the regression this test exists for. Failing
            // here rather than parking again keeps that a failed assertion instead
            // of a hung suite.
            guard await observer.entered.count == 1 else {
                throw ProbeError.modelReenteredAfterCancellation
            }
            insideTool.signal()
            await release.wait()
            // The one failure a budgeted turn compacts-and-retries on, raised with
            // a cancellation already outstanding against this turn.
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let turnTask = Task { try await session.respond(to: "overflow-then-cancel") }
        await insideTool.wait()
        // Both routes must behave identically here: neither may let the retry
        // re-enter the model on behalf of a turn already cancelled.
        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
        case .callerTask:
            turnTask.cancel()
        }
        release.signal()

        // The retry's model call never starts: the turn ends cancelled rather than
        // silently re-running the whole attempt, tool calls included.
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }
        #expect(await fixture.observer.entered == ["overflow-then-cancel"])
    }

    // MARK: - Queue-side cancellation is unchanged

    @Test("queue-side cancel of a still-pending prompt still produces no turn at all")
    @MainActor
    func queueSideCancellationStillProducesNoTurn() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let id = await session.enqueue(prompt: "queued")
        #expect(await session.cancel(id: id) == .applied)

        // Nothing dispatched, nothing generated, nothing recorded — the
        // additive in-flight primitive left the queue-side one exactly as it was.
        #expect(try await session.dispatchNextPrompt() == nil)
        #expect(await fixture.observer.entered.isEmpty)
        #expect(await fixture.recorder.events.isEmpty)
        #expect(await session.pendingPrompts().isEmpty)
    }

    // MARK: - A stop lands during a compaction fold too

    @Test(
        "cancelling a turn parked inside its proactive fold's summarizer call stops the fold instead of waiting it out",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellingAProactiveFoldStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let turnTask = Task { try await session.respond(to: "folds-first") }
        await insideSummarizer.wait()

        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
        case .callerTask:
            turnTask.cancel()
        }

        // A fold's summarizer call is a model call like any other, so both routes
        // reach the work running inside it and the turn unwinds with the same
        // `CancellationError` a cancelled generation gives.
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)
        #expect(await fixture.observer.toolSawCancellation)

        // No further model call is *entered* while unwinding: the stop costs no more
        // model work than the call it landed in. Deliberately not read as a guard on
        // the tier-degrading rule itself — `runCancellableModelCall`'s pre-flight
        // check refuses a later tier's call before the hook is ever reached, so this
        // count stays `1` either way. `cancelledProactiveFoldReportsNoCompaction` is
        // what pins the rule.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)

        // And the turn the fold was folding for never ran: with nothing under way
        // once the fold is gone, its own model call is never made.
        #expect(await fixture.observer.entered.contains("folds-first") == false)
    }

    @Test("a summarizer that raises CancellationError with no stop outstanding is an ordinary failure, and still degrades")
    @MainActor
    func summarizerCancellationErrorWithNoStopOutstandingStillDegrades() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        // `LanguageModelSessionBackend` is a public protocol, and a conformer is free
        // to surface `CancellationError` from internals of its own — a timeout, a
        // task group it manages — with nothing cancelled on this side at all. That is
        // an ordinary summarizer failure, so the fold must degrade to the next tier
        // exactly as it does for any other one, rather than reading the error's
        // *type* as a stop and killing a turn nobody asked to stop.
        let summarizerCalls = Mutex(0)
        fixture.hook.midTurn = { prompt in
            guard Self.isSummarizerCall(prompt) else { return }
            let isFirstCall = summarizerCalls.withLock { calls -> Bool in
                calls += 1
                return calls == 1
            }
            guard isFirstCall else { return }
            throw CancellationError()
        }

        // No cancel anywhere in this test, so this turn cannot park: it either folds
        // and answers, or fails.
        #expect(try await session.respond(to: "folds-first") == "ok-folds-first")

        // Two summarizer calls: the flash tier's failure, then the own-model tier
        // that actually produced the summary.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 2)
    }

    @Test("a genuine summarizer fault that coincides with a stop ends the turn as cancelled, and still does not degrade")
    @MainActor
    func summarizerFaultCoincidingWithAStopIsAbandonedAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        // The race this pins is the inverse of
        // ``summarizerCancellationErrorWithNoStopOutstandingStillDegrades()``: there a
        // cancellation-shaped error arrives with no stop outstanding, here a plainly
        // unrelated fault arrives with one. The stop wins — the caller is told its turn
        // was cancelled rather than handed a fold failure it never asked about, and the
        // fold is still not degraded to the next tier. What becomes of the discarded
        // fault is a log line rather than a rethrow, which is the one part of this no
        // test can observe (see ``RoutedSessionActor``'s abandoned-fold report).
        let insideSummarizer = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let parksOn = Self.firstSummarizerCall()
        fixture.hook.midTurn = { prompt in
            guard parksOn(prompt) else { return }
            insideSummarizer.signal()
            await release.wait()
            throw ProbeError.summarizerFailed
        }

        // Streamed, because the *only* observable difference between abandoning this
        // fold and degrading it to the deterministic-only tier is the
        // ``SessionEvent/compaction(_:)`` that tier's empty result would deliver — see
        // the assertion below.
        let delivered = DeliveredEvents()
        let turnTask = Task {
            for try await event in await session.streamEvents(to: "folds-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        #expect(await session.cancelCurrentTurn() == .requested)
        // Released by the test rather than by the cancellation, so this turn unwinds
        // through the fault's path and not through the parked tool's own.
        release.signal()

        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }
        // Not degraded: a fault is no licence to answer the stop by folding anyway.
        // This is the assertion that pins the rule — the summarizer-call count below
        // cannot, because a degraded tier's call is refused by
        // `runCancellableModelCall`'s pre-flight check before the hook is ever
        // reached, so it stays `1` either way (the same caveat
        // ``cancellingAProactiveFoldStopsIt(route:)`` records).
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)
        #expect(await fixture.observer.entered.contains("folds-first") == false)

        // And this path gave its gates back too, fault and stop together.
        fixture.hook.midTurn = nil
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "cancelling a caller-driven compact() stops it too, by either route — it holds the turn lock the same way",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellingACallerDrivenCompactStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Warmed up for its transcript alone here: a manual fold needs no trigger,
        // just enough old content for the model-assisted stage to have work to do.
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let compactTask = Task {
            try await session.compact(prompt: Self.foldSummarizerPrompt, budget: Self.summarizingFoldBudget)
        }
        await insideSummarizer.wait()

        // A manual fold is not a "turn" a caller ever asked to generate, but it holds
        // the turn lock and runs real model work, so a stop reaches it on exactly the
        // same terms — a caller no longer has to own an enclosing `Task` to get out.
        //
        // Both routes, because routing the summarizer through the turn's own
        // cancellable model call *changed* how the caller's route arrives here: a
        // caller's cancellation used to propagate structurally, through the very task
        // that called `compact()`, and now has to reach an unstructured task by
        // `withTaskCancellationHandler` and the pre-flight check instead. That is the
        // most-changed behavior on this path, so it is the one least safe to leave to
        // the other route's coverage.
        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
        case .callerTask:
            compactTask.cancel()
        }
        await Self.awaitCancelledUnwind(compactTask, observer: fixture.observer, parked: parked)
        #expect(await fixture.observer.toolSawCancellation)

        // And it gave its gates back on the way out, so the session still generates.
        fixture.hook.midTurn = nil
        #expect(await Self.followUpTurnCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "a turn cancelled inside its own proactive fold re-queues the outbox events it had drained",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveFoldRequeuesItsDrainedEvents(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        // Staged after the warm-up, so this turn is the one that drains it.
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(posted)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let turnTask = Task { try await session.respond(to: "folds-first") }
        await insideSummarizer.wait()
        // Both routes, because losing a drained outbox is a silent data-loss bug
        // rather than a visible failure: on the caller-cancels route the re-queue
        // itself runs inside an already-cancelled task, so nothing about it may
        // depend on the task still being live.
        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
        case .callerTask:
            turnTask.cancel()
        }
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // The fold threw before the turn ever reached the model, so nothing this
        // turn drained was delivered — and the drain must not have destroyed it.
        // The re-queue for this window is the whole reason the fold could not
        // simply be made to throw.
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }

    @Test(
        "a turn cancelled inside its own proactive fold reports no compaction, because none happened",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveFoldReportsNoCompaction(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let recordedBefore = await fixture.recorder.events.count

        // Streamed, because ``SessionEvent/compaction(_:)`` is only observable to a
        // consumer that asked for this turn's events.
        let delivered = DeliveredEvents()
        let turnTask = Task {
            for try await event in await session.streamEvents(to: "folds-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        // Both routes, because the rule this pins — a cancelled fold is abandoned
        // rather than degraded — is decided by a predicate that asks each route
        // separately, so its holding for one says nothing about the other.
        //
        // What the *consumer* sees is the one thing that genuinely differs by route
        // here, and it differs for a reason outside this package: cancelling a task
        // suspended in `AsyncThrowingStream.next()` **finishes** that stream rather
        // than throwing from it. So only the router-API route can be asserted with
        // ``awaitCancelledUnwind(_:observer:parked:)``.
        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
            // The consumer is not what was cancelled, so it is told: the stream ends
            // by throwing the turn's own `CancellationError`.
            await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)
        case .callerTask:
            // Cancelling the consumer terminates the stream, which cancels the task
            // the turn itself runs in — the abandoned-stream shape
            // ``abandoningAStreamRecordsTheTurnAsCancelled()`` pins from the other
            // side. What this route can therefore show is that the fold let go and
            // the consumer came back at all, not an error it could never observe.
            turnTask.cancel()
            guard await Self.awaitCancellationReachingTheTool(
                turnTask, observer: fixture.observer, parked: parked)
            else { return }
            // Safe to await, for ``followUpTurnEvents(on:observer:prompt:)``'s reason:
            // a stream consumer's `next()` is cancellation-aware and always ends.
            _ = try? await turnTask.value
        }

        // A cancelled fold is abandoned outright, not degraded down to the
        // deterministic-only tier the way a broken summarizer is: so the consumer is
        // never told a fold happened, and every `.compaction` this session reports
        // describes work it really did. Pinned by the router-API route — on the
        // caller-cancels one it holds trivially, since a consumer that cancelled itself
        // receives nothing further whatever the fold went on to do.
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)

        // What the caller-cancels route pins instead, and the reason it is worth
        // running: a streamed turn cut short inside its fold is recorded like every
        // other one — a lone bodyless close — even though on that route the recording
        // runs inside an already-cancelled task. Spun for rather than read straight,
        // because a cancelled consumer returns before the producer behind it has
        // finished recording (the same ordering
        // ``abandoningAStreamRecordsTheTurnAsCancelled()`` waits on).
        await Self.spin(until: { await fixture.recorder.events.count == recordedBefore + 1 })
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    @Test(
        "a turn cancelled inside its own proactive fold leaves the transcript exactly as it was, plus one close",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveFoldLeavesTheTranscriptUntouched(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.summarizingFoldBudget)

        let fillBefore = await session.contextFill
        let recordedBefore = await fixture.recorder.events.count

        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let turnTask = Task { try await session.respond(to: "folds-first") }
        await insideSummarizer.wait()
        // Both routes, because of the recording assertions below: on the
        // caller-cancels route the cut-short turn's own recording runs inside an
        // already-cancelled task, which is the riskier of the two for anything that
        // must still happen on the way out.
        switch route {
        case .routerAPI:
            #expect(await session.cancelCurrentTurn() == .requested)
        case .callerTask:
            turnTask.cancel()
        }
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // Never a half-applied fold: a fold records its new entries, swaps
        // `backend`, and reports its own post-fold size as this session's fill —
        // all of it only once the summarizer has returned. An abandoned fold does
        // none of it, so measured fill is byte-identical to what it was before.
        #expect(await session.contextFill == fillBefore)

        // Recorded like every other failed turn, and no differently for having
        // been cut short in a fold: exactly one close, bodyless, with no `.prompt`
        // of its own because the model was never called.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)

        // The session keeps working, and the abandoned fold left the transcript it
        // was folding alone: the *next* turn folds for real, and its fold measures
        // exactly the untouched warm-up transcript. Had the cancelled fold swapped
        // `backend` for a folded one, this would measure the smaller, folded size —
        // which is what makes this an assertion about `backend` itself and not only
        // about the ordering inside `fold`. The hook is cleared first, or that next
        // fold would park in the summarizer all over again.
        fixture.hook.midTurn = nil
        let followUp = try #require(await Self.followUpTurnEvents(on: session, observer: fixture.observer))
        let untouchedSize = Compactor.estimatedTokenCount(of: Transcript(entries: Self.warmUpEntries()))
        let folds = followUp.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(folds.map(\.tokensBefore) == [untouchedSize])
    }

    @Test("cancelling a turn inside its reactive compact-and-retry-once fold stops the retry, leaving one close")
    @MainActor
    func cancellingTheReactiveFoldStopsTheRetry() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Unmetered, so the proactive gate never fires and the only fold in play is
        // the one this turn's own context overflow triggers.
        let session = try await Self.makeFoldTriggeredSession(
            fixture, budget: Self.summarizingFoldBudget, metersTriggeringFill: false)

        let recordedBefore = await fixture.recorder.events.count
        let insideSummarizer = AsyncSemaphore(value: 0)
        let parked = Self.parkInsideCancellationAwareTool(
            fixture, parkingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        // Composed on top of the summarizer park rather than replacing it: this turn
        // has to overflow *and then* park inside the fold that overflow triggers.
        let parkInSummarizer = fixture.hook.midTurn
        fixture.hook.midTurn = { prompt in
            guard prompt.hasSuffix(Self.overflowingFoldPrompt) else {
                try await parkInSummarizer?(prompt)
                return
            }
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let turnTask = Task { try await session.respond(to: Self.overflowingFoldPrompt) }
        await insideSummarizer.wait()
        #expect(await session.cancelCurrentTurn() == .requested)
        await Self.awaitCancelledUnwind(turnTask, observer: fixture.observer, parked: parked)

        // The retry never ran: the model saw this turn exactly once, and what the
        // caller gets is the cancellation rather than the overflow it was recovering
        // from.
        #expect(await fixture.observer.entered.filter { $0.hasSuffix(Self.overflowingFoldPrompt) }.count == 1)

        // One close, not two: the failed attempt's own, recorded before the fold
        // started. The retry that would have written the second never happened, and
        // the cancelled fold adds none of its own.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 2)
        #expect(Array(recorded.map(\.kind).suffix(2)) == [.prompt, .response])
        #expect(recorded.last?.text == nil)
    }

    @Test("a deterministic-only fold with no cancellation outstanding folds and runs its turn exactly as before")
    @MainActor
    func deterministicOnlyFoldIsUnaffected() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeFoldTriggeredSession(fixture, budget: Self.deterministicFoldBudget)

        // No hook installed, and none needed: this fold makes no model call at all,
        // which is exactly what must stay true — a cheap fold gained no cancellation
        // check of its own.
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: "folds-deterministically") {
            events.append(event)
        }

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the turn's first event to be .compaction, got \(String(describing: events.first))")
            return
        }
        #expect(result.stagesApplied == [ToolOutputElision.stageName, TurnTruncation.stageName])
        #expect(result.summary == nil)
        #expect(await fixture.observer.entered.contains(where: Self.isSummarizerCall) == false)

        // And the turn's own work ran normally straight after the fold.
        let streamedText = events.compactMap { event -> String? in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
        #expect(streamedText == "ok-folds-deterministically")
    }
}

