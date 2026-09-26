import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/cancel()``: cancelling the answer that already
/// **runs**, as opposed to ``RoutedSession/cancel(message:)``'s withdrawal
/// of a message that waits for a submission.
///
/// The chain this closes is `ACP session/cancel` -> Router -> MCP
/// `notifications/cancelled`: `FoundationModelsMCP` already turns Swift task
/// cancellation into the protocol-level notification, and a client stop already
/// reaches Router — so the only missing link was Router's own ability to cancel
/// the `Task` that owns the model call a tool runs inside. These tests prove
/// cancellation reaches *inside* the model call (the regression the work exists
/// for), that a cancelled submission is recorded exactly like any other failed
/// submission rather than half-written, that the pump of the session survives
/// it, and that the documented no-op cases really are no-ops.
///
/// Everything runs against stubs with no network and no GPU: a backend whose
/// `respond` runs a test-supplied closure mid-generation stands in for the SDK
/// invoking a tool inside the model call, exactly as in
/// ``HumanWaitGateTests``. Determinism comes from ``AsyncSemaphore``
/// observability rather than from sleeps.
///
/// The moment every test here depends on — a cancellation reaching the tool call
/// running inside the model call — is an ``AwaitedEvent`` the tool itself signals,
/// rather than a reading polled until a wall clock runs out (task ^bqj719z).
///
/// A clock was the wrong measure because the crossing is not quick on every route.
/// ``RoutedSession/cancel()`` cancels the model call directly, so the
/// stop lands in microseconds. A caller cancelling its own stream consumer reaches
/// the tool only once that consumer runs *again*: the consumer's next `next()`
/// terminates the stream, the termination handler cancels the answer behind it, and
/// only then does the stop travel on. That consumer is `@MainActor`, so it runs
/// when the one main actor every `@MainActor` test in the run shares gives it a
/// slot. Measured on ``cancelledProactiveCompactionReportsNoCompaction(route:)``: the
/// wait takes tens of microseconds run alone and under `--no-parallel`, and about
/// two seconds in half of the full parallel runs. That number reads the run, not
/// Router, so a five-second ceiling over it is a coin toss on a busier machine.
///
/// Waited on instead, a slower run makes such a test slower and never red. What
/// ends a wait the cancellation genuinely never reaches — the regression these
/// tests exist to catch — is the `.timeLimit` below: a ceiling on a fault, thirty
/// times the slowest crossing measured, and never a budget for the work.
@Suite(
    "The cancel of a running answer reaches the model call, and the tools inside it",
    .timeLimit(.minutes(1)))
struct AnswerCancellationTests {
    /// The two routes that can cancel a running answer, so a test can assert
    /// the same behavior of both instead of duplicating itself per route.
    enum CancellationRoute: Sendable, CaseIterable, CustomTestStringConvertible {
        /// ``RoutedSession/cancel()`` — Router's own primitive.
        case routerAPI

        /// The caller of the answer cancelling its own enclosing `Task` — the propagation
        /// Router had before it had a primitive of its own.
        case callerTask

        var testDescription: String {
            switch self {
            case .routerAPI: "cancel()"
            case .callerTask: "the caller's own Task"
            }
        }
    }

    /// Failures a test's own stand-in tool raises — to mark a path that must never
    /// be taken, or to stand in for a fault the model itself would raise.
    private enum ProbeError: Error, Equatable {
        /// The overflow retry re-entered the model even though the answer had
        /// already been cancelled.
        case modelReenteredAfterCancellation

        /// A summarizer call failed for a reason of its own, with nothing about it
        /// cancellation-shaped.
        case summarizerFailed
    }

    // MARK: - Answer observability

    /// Records which answers entered and left the model and whether a tool
    /// running inside the model call ever observed cancellation, so
    /// propagation past `body` is asserted rather than inferred.
    private actor AnswerObserver {
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

    /// Collects the events a streaming answer delivered before it failed.
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
    /// SDK invokes *inside* the model call. It gets the prompt of the
    /// submission, so one hook can serve several sessions and suspend only the
    /// answer a test means to suspend.
    ///
    /// A plain mutable class rather than an actor because
    /// ``HookedSessionBackend/respond(to:maxTokens:)`` reads it from whatever
    /// isolation the submission runs on: `@unchecked Sendable` is safe because
    /// ``midAnswer`` is written exactly once, on the single `@MainActor` test
    /// task, before any answer starts, and only read afterwards.
    private final class AnswerHook: @unchecked Sendable {
        var midAnswer: (@Sendable (String) async throws -> Void)?
    }

    // MARK: - Stub container + backend

    /// A ``LanguageModelSessionBackend`` that runs ``AnswerHook/midAnswer`` in the
    /// middle of `respond`, standing in for a long-running MCP tool call the
    /// SDK invokes from inside the model call.
    ///
    /// ``appendsPromptBeforeToolCall`` decides whether the `.prompt` entry of
    /// this submission is already in the transcript when the tool runs — which
    /// is exactly what decides the outbox rule of a cancelled submission: a
    /// submission whose prompt was durably appended really did deliver its
    /// drained events to the model, and one that appended nothing never did.
    ///
    /// Properly `Sendable` rather than `@unchecked`, unlike ``StubSessionBackend``,
    /// because on this backend the transcript really is shared: the streaming path
    /// produces from a task of its own, and a submission cancelled mid-stream stops
    /// consuming (and goes on to read ``transcriptEntries()`` for its diff) while
    /// that producer is still live. Whether the two actually overlap depends on
    /// what the installed hook does about cancellation, which is no basis for a
    /// data-race argument — so ``entries`` is behind a ``Mutex`` and the question
    /// does not arise.
    private final class HookedSessionBackend: LanguageModelSessionBackend {
        private let hook: AnswerHook
        private let observer: AnswerObserver
        private let appendsPromptBeforeToolCall: Bool

        /// This backend's synthetic transcript.
        private let transcript: Mutex<[Transcript.Entry]>

        /// This backend's synthetic transcript, as of this read.
        var entries: [Transcript.Entry] { transcript.withLock { $0 } }

        /// What ``usageTokenCounts()`` reports: how many input tokens each
        /// completed submission adds to a running total, and that total so far.
        private struct Metering {
            /// The input tokens one completed submission adds, or `nil` for a
            /// backend that reports no usage at all.
            var inputTokensPerSubmission: Int?

            /// The input tokens of every metered submission so far.
            var totalInputTokens = 0
        }

        /// This backend's measured usage — behind a lock for the same reason
        /// ``transcript`` is, and mutable because a compaction fixture starts metering
        /// between two answers.
        private let metering: Mutex<Metering>

        init(
            hook: AnswerHook,
            observer: AnswerObserver,
            appendsPromptBeforeToolCall: Bool,
            entries: [Transcript.Entry] = [],
            inputTokensPerSubmission: Int? = nil
        ) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
            self.transcript = Mutex(entries)
            self.metering = Mutex(Metering(inputTokensPerSubmission: inputTokensPerSubmission))
        }

        /// The input tokens each completed submission adds to this backend's
        /// measured usage, as of this read — carried over to every backend
        /// derived from this one, so a compaction that swaps the session's
        /// backend does not silently stop it measuring.
        var inputTokensPerSubmission: Int? { metering.withLock { $0.inputTokensPerSubmission } }

        /// Starts reporting measured usage: `inputTokensPerSubmission` input
        /// tokens for every submission completed from here on.
        ///
        /// A compaction fixture starts metering only for its *last* warm-up
        /// answer: a session measuring usage from its first answer would cross
        /// its budget's trigger with almost nothing in its transcript, and a
        /// compaction with no old span left to summarize never makes a
        /// summarizer call at all.
        ///
        /// - Parameter inputTokensPerSubmission: The input tokens each
        ///   completed submission adds to the running total.
        func startMetering(inputTokensPerSubmission: Int) {
            metering.withLock { $0.inputTokensPerSubmission = inputTokensPerSubmission }
        }

        /// Adds the measured input tokens of one completed submission to the
        /// running total, so the own delta of that submission — the difference
        /// between the snapshots the session takes either side of it — is
        /// exactly ``Metering/inputTokensPerSubmission``.
        private func meterOneSubmission() {
            metering.withLock { state in
                guard let perSubmission = state.inputTokensPerSubmission else { return }
                state.totalInputTokens += perSubmission
            }
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            if appendsPromptBeforeToolCall {
                appendPrompt(prompt)
            }
            await observer.enter(prompt)
            if let midAnswer = hook.midAnswer {
                do {
                    try await midAnswer(prompt)
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
            meterOneSubmission()
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
                            segments: [.text(Transcript.TextSegment(content: responseText))]))
                )
            }
        }

        /// The chunk a streaming submission yields *before* running the tool hook —
        /// what a consumer has already received by the time a cancellation lands.
        static let firstStreamedChunk = "ok-"

        /// Streams the response in two chunks with ``AnswerHook/midAnswer`` run
        /// between them, so a streaming submission suspends inside a tool call
        /// exactly like a whole-response one — and a test can tell that the
        /// consumer kept the chunk it had already been handed when the
        /// cancellation landed.
        ///
        /// The transcript entries land in the same places relative to the tool call
        /// as ``respond(to:maxTokens:)`` puts them, so
        /// ``appendsPromptBeforeToolCall`` means the same thing on both paths. They
        /// are written from this stream's own producer task, which can outlive the
        /// consumption of the stream by the submission — see ``transcript``, which is why they
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
                    if let midAnswer = hook.midAnswer {
                        do {
                            try await midAnswer(prompt)
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
                    self.meterOneSubmission()
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

        /// This backend's measured usage, or `nil` until ``startMetering(inputTokensPerSubmission:)``
        /// is called — the default, and what every test here but the compaction ones
        /// wants: a session with no measured usage has no measured
        /// ``RoutedSession/contextFill``, so no proactive compaction can trigger.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            metering.withLock { state -> (input: Int, output: Int)? in
                guard state.inputTokensPerSubmission != nil else { return nil }
                return (input: state.totalInputTokens, output: 0)
            }
        }

        func makeFork() -> any LanguageModelSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall,
                entries: entries, inputTokensPerSubmission: inputTokensPerSubmission)
        }

        /// Honors the replacement transcript rather than taking
        /// ``LanguageModelSessionBackend``'s `makeFork()`-based default, which
        /// keeps this backend's own entries instead.
        ///
        /// A compaction swaps the session's backend for one seeded with the *compacted*
        /// transcript and sets `persistedEntryCount` from that same transcript, so
        /// a fixture that ignored the replacement would leave the two disagreeing
        /// and have the diff of the next submission record entries no real
        /// session would. The running usage total deliberately starts over, the
        /// way a genuinely new session over the same model does; the measurement
        /// for each submission carries on.
        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall,
                entries: Array(transcript), inputTokensPerSubmission: inputTokensPerSubmission)
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer.
    ///
    /// Almost every test here observes answers through the shared ``AnswerObserver``
    /// and the recorder rather than by reaching for a particular session's
    /// backend; the exception is ``lastVendedBackend``, which the compaction fixture
    /// needs (see its doc), so the vended backend is retained behind a lock.
    private final class HookedLLMContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        private let hook: AnswerHook
        private let observer: AnswerObserver
        private let appendsPromptBeforeToolCall: Bool

        /// The most recently vended backend.
        private let lastVended = Mutex<HookedSessionBackend?>(nil)

        init(hook: AnswerHook, observer: AnswerObserver, appendsPromptBeforeToolCall: Bool) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
        }

        /// The backend this container vended most recently — the one the session
        /// built right after it is driving.
        ///
        /// The only way to reach it: `RoutedSessionActor.backend` is `private` and
        /// ``RoutedSession`` exposes no accessor for it, and
        /// ``makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)`` has to start metering on the
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
    /// every generation slot — so every session in a test shares one model. No
    /// download, no GPU.
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
            "max_position_embeddings": 8192,
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
    private static let noOpCompactionScale = 100_000

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
    private static let unreachableFillTrigger = 2.0

    /// The fraction of ``noOpCompactionScale`` a compaction aims to come down to, spelled out
    /// rather than left to the `0.50` default so the compaction's target size is
    /// visible at the call site.
    ///
    /// Inert either way: at this scale the target — and the overflow retry's
    /// target, which is never above it — stays far above the transcript.
    private static let inertCompactionTarget = 0.25

    /// The auto-compaction opt-in ``cancellationSurvivesIntoTheOverflowRetry(route:)``
    /// vends its session with: enough to switch on the reactive
    /// compact-and-retry-once recovery, and nothing else.
    private static let unreachableTriggerBudget = TokenBudget(
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
    private static let compactionSummarizerPrompt = CompactionPrompt(
        name: "answer-cancellation-compaction-suspend",
        text: "SUSPEND-INSIDE-THE-COMPACTION"
    )

    /// Whether the model call carrying `prompt` is a compaction's own summarizer call.
    private static let isSummarizerCall: @Sendable (String) -> Bool = {
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

    /// How many warm-up answers ``makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)`` drives
    /// before the answer that compacts, so the compaction has a conversation to
    /// summarize and therefore a real summarizer call to make.
    private static let compactionWarmUpAnswerCount = 6

    /// The measured fill a compaction test's budget compacts at — ``TokenBudget``'s own
    /// default trigger, spelled out because these budgets are built by
    /// ``compactionBudget(targetTokens:)`` rather than by ``TokenBudget/init(limit:trigger:target:hardCeiling:toolOutputLimit:)``.
    private static let compactionFillTrigger = 0.8

    /// The share of the session's own resolved context window the last warm-up
    /// answer measures, above ``compactionFillTrigger`` so the *next* answer compacts.
    private static let compactionTriggeringFillFraction = 0.9

    /// The fraction of a compaction budget's `limit` its target sits at — an arbitrary
    /// choice ``compactionBudget(targetTokens:)`` inverts, present only so a wanted
    /// target size can be stated directly instead of back-computed at each call
    /// site.
    private static let compactionTargetFraction = 0.25

    /// A budget that compacts to `targetTokens`, stated as the size it lands on
    /// rather than as ``TokenBudget``'s own `limit`/`target` pair —
    /// ``Compactor`` compacts to `limit * target`, so this inverts that.
    ///
    /// - Parameter targetTokens: The size, in tokens, the compaction should aim for.
    /// - Returns: A budget with that target size and ``compactionFillTrigger``'s trigger.
    private static func compactionBudget(targetTokens: Int) -> TokenBudget {
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
    private static let overflowingCompactionPrompt = "overflows-then-compacts"

    /// The prompt ``makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)``'s
    /// warm-up answer `index` sends.
    private static func warmUpPrompt(_ index: Int) -> String { "warm-\(index)" }

    /// The exact transcript entries those warm-up answers leave behind, computed
    /// without running a session: ``HookedSessionBackend`` appends one `.prompt`
    /// carrying the own prompt of the answer and one `.response` carrying
    /// `"ok-"` plus it, so both budgets below can be sized up front from this
    /// alone.
    private static func warmUpEntries() -> [Transcript.Entry] {
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
    private static var summarizingCompactionBudget: TokenBudget {
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
    private static func makeCompactionTriggeredSession(
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

    private static func makeTempDir() -> URL {
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
    private static func followUpAnswerCompletes(
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
    private static func followUpAnswerEvents(
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
    private struct Fixture {
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
    private static func makeFixture(
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
    private static func suspendInsideCancellationAwareTool(
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
    private static func suspendInsideCancellationAwareTool(
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
    private static func awaitCancelledUnwind<Value: Sendable>(
        _ answerTask: Task<Value, Error>,
        sawCancellation: AwaitedEvent
    ) async throws {
        try await sawCancellation.wait()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
    }

    // MARK: - The regression: a stop must reach a running tool call

    @Test("cancel() cancels the model call of the running answer, and the tool running inside it sees CancellationError")
    @MainActor
    func cancellingARunningAnswerReachesTheToolCall() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        #expect(await session.cancel() == .requested)

        // The whole point: the tool call *inside* the model call observes the
        // cancellation, and the answer then unwinds with it.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
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
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "caller-cancels", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "caller-cancels") }
        await insideTool.wait()

        // Router runs the model call in a task of its own so it can cancel it
        // from outside; that must not cost the caller the propagation plan.md
        // always promised from cancelling its own enclosing `Task`.
        answerTask.cancel()

        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // Recorded the same way as a submission cancelled through `cancel()`,
        // even though this cancellation unwinds the task the recording itself runs
        // in: nothing on the recording path observes cancellation, so a
        // caller-cancelled submission is no more half-written than any other failed one.
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == nil)
    }

    // MARK: - Recording

    @Test("a cancelled submission is recorded exactly like any other failed submission, and the session keeps working")
    @MainActor
    func cancelledSubmissionLeavesAConsistentTranscript() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Whatever the SDK durably appended before the cancellation landed (the
        // `.prompt` entry of the submission), plus exactly one close — the
        // synthetic bodyless `.response` every failed submission gets, never two
        // and never none.
        let cancelledSubmissionEvents = await fixture.recorder.events
        #expect(cancelledSubmissionEvents.map(\.kind) == [.session, .prompt, .response])
        let close = try #require(cancelledSubmissionEvents.last)
        #expect(close.text == nil)
        #expect(close.ms != nil)

        // Nothing was left half-written: an ordinary answer on the same session
        // records its own whole prompt/response pair straight after. Run through
        // `followUpAnswerCompletes` rather than awaited directly, so a regression
        // that stranded the pump fails here instead of suspending the follow-up
        // answer — and the suite with it — forever.
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        let afterEvents = await fixture.recorder.events
        #expect(afterEvents.map(\.kind) == [.session, .prompt, .response, .prompt, .response])
        #expect(afterEvents.last?.text == "ok-after")
    }

    // MARK: - Nothing stranded

    @Test("cancelling an answer whose tool body waits for a person leaves the session idle and blocks no other session")
    @MainActor
    func cancellingAnAnswerThatWaitsForAPersonLeavesTheSessionIdle() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let sessionA = fixture.model.makeSession()
        let sessionB = fixture.model.makeSession()

        // The tool body of the answer waits for a person, directly, when the
        // cancellation arrives: the interaction between the cancel of a running
        // answer and a wait inside a tool body. The session has no wrapper for
        // such a wait, so the wait holds nothing of its own.
        let insideWait = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, prompt: "cancel-in-wait", insideTool: insideWait)

        let answerTask = Task { try await sessionA.respond(to: "cancel-in-wait") }
        await insideWait.wait()
        #expect(await sessionA.isPumpRunning)

        #expect(await sessionA.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The answer ended, and nothing of it waits.
        #expect(await sessionA.becomesIdle())

        // The behavioral proof: another session over the same model still
        // generates, and so does the cancelled one.
        #expect(await Self.followUpAnswerCompletes(on: sessionB, observer: fixture.observer, prompt: "other-session"))
        #expect(await Self.followUpAnswerCompletes(on: sessionA, observer: fixture.observer))
        #expect(await sessionA.becomesIdle())
    }

    // MARK: - The outbox rule

    @Test("a cancelled submission that durably delivered its drained events records them rather than re-queueing them")
    @MainActor
    func cancelledSubmissionKeepsDeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends the `.prompt` entry of the submission before the tool runs,
        // so the composed preamble carrying the drained event really did reach
        // the model before the cancellation landed.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: true)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Delivered, so not re-queued: the drained event rode the recorded
        // prompt of the cancelled submission and is not staged again.
        let pending = await session.outbox.pending()
        #expect(pending.events.isEmpty)
        let promptEvent = try #require(await fixture.recorder.events.first { $0.kind == .prompt })
        #expect(promptEvent.text?.contains("run command") == true)
    }

    @Test("a cancelled submission that delivered nothing re-queues its drained events instead of destroying them")
    @MainActor
    func cancelledSubmissionRequeuesUndeliveredEvents() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This backend appends nothing before the tool runs, so a cancellation
        // there leaves the submission with no `.prompt` partial for the drained event
        // to attach to — it was never durably delivered.
        let fixture = try await Self.makeFixture(cacheDir: dir, appendsPromptBeforeToolCall: false)
        let session = fixture.model.makeSession()
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "cancel-me", insideTool: insideTool)

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }

    // MARK: - The streaming and queue-dispatch entry points

    @Test("cancel() finishes a streamEvents answer with CancellationError, leaving the consumer what it already received")
    @MainActor
    func cancellingAStreamingAnswerFinishesTheStreamWithCancellationError() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "stream-cancel", insideTool: insideTool)

        // The stream is drained into `delivered` as it arrives, so what the consumer
        // had already been handed survives the error the stream finishes with.
        let delivered = DeliveredEvents()
        let answerTask = Task { () throws -> Int in
            for try await event in await session.streamEvents(to: "stream-cancel") {
                await delivered.append(event)
            }
            return await delivered.events.count
        }
        await insideTool.wait()

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Everything the answer produced before the cancellation is still the
        // consumer's — a cancelled stream is truncated, not retracted.
        #expect(await delivered.events.contains(.textDelta(HookedSessionBackend.firstStreamedChunk)))
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])

        // The cancelled chain ends with one answerFailed with the reason
        // cancelled. It is the last event before the stream throws, and it
        // names the one message of the stream.
        let deliveredEvents = await delivered.events
        _ = eventsInsideAnswerFrame(deliveredEvents)
        let failure = try #require(deliveredEvents.answerFailures.first)
        #expect(deliveredEvents.answerFailures.count == 1)
        #expect(deliveredEvents.answers.isEmpty)
        #expect(failure.reason == .cancelled)
        #expect(failure.messageIds.count == 1)
        #expect(deliveredEvents.last == .answerFailed(failure))
    }

    @Test("cancelling the submission of a sent message unwinds it, and the message is then answered")
    @MainActor
    func cancellingTheSubmissionOfASentMessageAnswersIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "send-cancel", insideTool: insideTool)

        // Restates the old dispatchNextPrompt() test: `send` starts the
        // submission, and no other call is necessary.
        let sent = await session.send("send-cancel")
        await insideTool.wait()

        #expect(await session.cancel() == .requested)
        try await sawCancellation.wait()
        #expect(await session.becomesIdle())

        // The pump took the message into the submission, and the cancel does
        // not put it back: the message is spent, and its id reports that its
        // answer came.
        #expect(await session.pendingMessages().isEmpty)
        #expect(await session.cancel(message: sent) == .alreadyAnswered)
    }

    // MARK: - No-ops and best-effort honesty

    @Test("cancelling twice, and cancelling after the answer has finished, are safe no-ops")
    @MainActor
    func cancellingTwiceAndAfterCompletionIsASafeNoOp() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // Before any answer: nothing to cancel.
        #expect(await session.cancel() == .nothingToCancel)

        // This tool unwinds only when the test says so, rather than out of its own
        // cancellation handler: a tool that unwinds the moment cancellation lands
        // lets the whole answer finish between the two calls below, which makes
        // "twice against one running answer" a race rather than a test. It still
        // ends in a real cancellation — it checks for one once released.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midAnswer = { prompt in
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

        let answerTask = Task { try await session.respond(to: "cancel-me") }
        await insideTool.wait()

        // Twice while the same answer provably still runs: the second call
        // requests what was already requested and changes nothing.
        #expect(await session.cancel() == .requested)
        #expect(await session.cancel() == .requested)

        release.signal()
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.toolSawCancellation)

        // After it has finished: no answer to cancel, and the request left
        // behind cannot bleed into the next answer — which is a claim about the
        // pump too, so the follow-up answer goes through
        // `followUpAnswerCompletes` rather than being awaited directly.
        #expect(await session.cancel() == .nothingToCancel)
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
        #expect(await session.cancel() == .nothingToCancel)
    }

    @Test("an answer whose model work ignores cancellation still completes — Router stopped listening, the work did not stop")
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
        fixture.hook.midAnswer = { prompt in
            guard prompt == "stubborn" else { return }
            insideTool.signal()
            await release.wait()
        }

        let answerTask = Task { try await session.respond(to: "stubborn") }
        await insideTool.wait()
        #expect(await session.cancel() == .requested)

        // Nothing Router can do makes it stop, so the answer runs to completion
        // and is recorded as the whole submission it was.
        release.signal()
        #expect(try await answerTask.value == "ok-stubborn")
        #expect(await fixture.recorder.events.map(\.kind) == [.session, .prompt, .response])
        #expect(await fixture.recorder.events.last?.text == "ok-stubborn")
    }

    @Test("a respond cancelled while its message waits behind another submission never reaches the model, and records nothing")
    @MainActor
    func cancellingAQueuedMessageNeverReachesTheModel() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // The first submission suspends inside the model without checking
        // cancellation, so the second message provably waits in the outbox
        // rather than racing to start.
        let insideFirstAnswer = AsyncSemaphore(value: 0)
        let releaseFirstAnswer = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("holds-the-lock") else { return }
            insideFirstAnswer.signal()
            await releaseFirstAnswer.wait()
        }

        let firstTask = Task { try await session.respond(to: "holds-the-lock") }
        await insideFirstAnswer.wait()

        let queuedTask = Task { try await session.respond(to: "queued-and-cancelled") }
        #expect(
            await BoundedWait.conditionReached("the second message waiting in the outbox") {
                await session.outbox.waitingMessageCount == 1
            })

        // Cancelled while its message waits. The message leaves the outbox,
        // or the pump drops it when it takes it: it never goes into a
        // submission.
        queuedTask.cancel()
        releaseFirstAnswer.signal()
        #expect(try await firstTask.value == "ok-holds-the-lock")

        // It throws rather than generating: the model is never called for this
        // message at all — which is the one case where a cancel of work that
        // ignores it still gives no response (see
        // ``RoutedSession/cancel()``).
        await #expect(throws: CancellationError.self) {
            try await queuedTask.value
        }
        #expect(await fixture.observer.entered == ["holds-the-lock"])

        // No submission carried the message, so the record holds only the
        // first submission's whole prompt/response pair.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == "ok-holds-the-lock")
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("abandoning a stream while its answer runs cancels the submission behind it, which is then recorded as cancelled rather than completed")
    @MainActor
    func abandoningAStreamRecordsTheSubmissionAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A tool that never checks cancellation, so what is asserted below is the
        // own outcome of the *submission* rather than the tool's cooperation.
        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        fixture.hook.midAnswer = { prompt in
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

        // Waiting for the tool to suspend first keeps the assertion below deterministic:
        // the diff of the submission must run while the backend still has no
        // `.response` entry for it, which is exactly the state a cut-short
        // submission is in.
        await insideTool.wait()
        await BoundedWait.spin(until: { await fixture.recorder.events.count == 3 })

        // Not "a submission that finished with a short response": a cancelled
        // submission, with the same lone bodyless close every other failed
        // submission gets.
        let events = await fixture.recorder.events
        #expect(events.map(\.kind) == [.session, .prompt, .response])
        #expect(events.last?.text == nil)

        // Let the abandoned producer drain rather than leaving it suspended for the
        // rest of the suite.
        release.signal()
        await BoundedWait.spin(until: { await fixture.observer.exited.contains("abandon-stream") })
        #expect(await fixture.observer.exited.contains("abandon-stream"))
    }

    // MARK: - A cancellation is not forgotten between the submissions of an answer

    @Test(
        "a cancellation landing during a failed attempt stops the overflow retry from re-running the model",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellationSurvivesIntoTheOverflowRetry(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // A budget makes this session recover from context overflow by compaction
        // harder and retrying once — and that retry is the window where the pump
        // runs the answer with no model call outstanding, so a cancellation
        // arriving in it has no task to cancel and must be remembered instead.
        let session = fixture.model.makeSession(budget: Self.unreachableTriggerBudget)

        let insideTool = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let observer = fixture.observer
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix("overflow-then-cancel") else { return }
            // A second call means the retry re-ran the model after the answer was
            // already cancelled — the regression this test exists for. Failing
            // here rather than suspending again keeps that a failed assertion instead
            // of a hung suite.
            guard await observer.entered.count == 1 else {
                throw ProbeError.modelReenteredAfterCancellation
            }
            insideTool.signal()
            await release.wait()
            // The one failure a budgeted answer compacts-and-retries on, raised
            // with a cancellation already outstanding against this answer.
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let answerTask = Task {
            try await session.respond(to: "overflow-then-cancel")
        }
        await insideTool.wait()
        // Both routes must behave identically here: neither may let the retry
        // re-enter the model on behalf of an answer already cancelled.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        release.signal()

        // The retry's model call never starts: the answer ends cancelled rather
        // than silently re-running the whole submission, tool calls included.
        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        #expect(await fixture.observer.entered == ["overflow-then-cancel"])
    }

    // MARK: - Queue-side cancellation is unchanged

    @Test("cancel(message:) of a waiting message still produces no submission for it")
    @MainActor
    func withdrawingAWaitingMessageStillProducesNoSubmission() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = fixture.model.makeSession()

        // A running submission keeps the session busy, so the next message
        // waits in the outbox.
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(fixture, prompt: "busy", insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: "busy") }
        await insideTool.wait()

        let id = await session.send("queued")
        #expect(await session.cancel(message: id) == .withdrawn)

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await session.becomesIdle())

        // The withdrawn message never reached the model: the cancel of the
        // running answer left the queue-side one as it was.
        #expect(await fixture.observer.entered == ["busy"])
        #expect(await session.pendingMessages().isEmpty)
    }

    // MARK: - A stop lands during a compaction too

    @Test(
        "cancelling an answer suspended inside its proactive compaction's summarizer call stops the compaction instead of waiting it out",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellingAProactiveCompactionStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()

        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }

        // A compaction's summarizer call is a model call like any other, so both routes
        // reach the work running inside it and the answer unwinds with the same
        // `CancellationError` a cancelled generation gives.
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // No further model call is *entered* while unwinding: the stop costs no more
        // model work than the call it landed in. Deliberately not read as a guard on
        // the tier-degrading rule itself — `runCancellableModelCall`'s pre-flight
        // check refuses a later tier's call before the hook is ever reached, so this
        // count stays `1` either way. `cancelledProactiveCompactionReportsNoCompaction` is
        // what pins the rule.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)

        // And the submission the compaction was running for never ran: with nothing under way
        // once the compaction is gone, its own model call is never made.
        #expect(await fixture.observer.entered.contains("compacts-first") == false)
    }

    @Test("a summarizer that raises CancellationError with no stop outstanding is an ordinary failure, and still degrades")
    @MainActor
    func summarizerCancellationErrorWithNoStopOutstandingStillDegrades() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // `LanguageModelSessionBackend` is a public protocol, and a conformer is free
        // to surface `CancellationError` from internals of its own — a timeout, a
        // task group it manages — with nothing cancelled on this side at all. That is
        // an ordinary summarizer failure, so the compaction must degrade to the next tier
        // exactly as it does for any other one, rather than reading the error's
        // *type* as a stop and killing an answer nobody asked to stop.
        let summarizerCalls = Mutex(0)
        fixture.hook.midAnswer = { prompt in
            guard Self.isSummarizerCall(prompt) else { return }
            let isFirstCall = summarizerCalls.withLock { calls -> Bool in
                calls += 1
                return calls == 1
            }
            guard isFirstCall else { return }
            throw CancellationError()
        }

        // No cancel anywhere in this test, so this answer cannot suspend: it either compacts
        // and answers, or fails.
        #expect(try await session.respond(to: "compacts-first") == "ok-compacts-first")

        // Two summarizer calls: the flash tier's failure, then the own-model tier
        // that actually produced the summary.
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 2)
    }

    @Test("a genuine summarizer fault that coincides with a stop ends the answer as cancelled, and still does not degrade")
    @MainActor
    func summarizerFaultCoincidingWithAStopIsAbandonedAsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // The race this pins is the inverse of
        // ``summarizerCancellationErrorWithNoStopOutstandingStillDegrades()``: there a
        // cancellation-shaped error arrives with no stop outstanding, here a plainly
        // unrelated fault arrives with one. The stop wins — the caller is told its answer
        // was cancelled rather than handed a compaction failure it never asked about, and the
        // compaction is still not degraded to the next tier. What becomes of the discarded
        // fault is a log line rather than a rethrow, which is the one part of this no
        // test can observe (see ``RoutedSessionActor``'s abandoned-compaction report).
        let insideSummarizer = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let suspendsOn = Self.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard suspendsOn(prompt) else { return }
            insideSummarizer.signal()
            await release.wait()
            throw ProbeError.summarizerFailed
        }

        // Streamed, because the *only* observable difference between abandoning this
        // compaction and letting it finish is the ``SessionEvent/compaction(_:)``
        // a finished compaction would deliver — see the assertion below.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        #expect(await session.cancel() == .requested)
        // Released by the test rather than by the cancellation, so this answer unwinds
        // through the fault's path and not through the suspended tool's own.
        release.signal()

        await #expect(throws: CancellationError.self) {
            try await answerTask.value
        }
        // Not degraded: a fault is no licence to answer the stop by compaction anyway.
        // This is the assertion that pins the rule — the summarizer-call count below
        // cannot, because a degraded tier's call is refused by
        // `runCancellableModelCall`'s pre-flight check before the hook is ever
        // reached, so it stays `1` either way (the same caveat
        // ``cancellingAProactiveCompactionStopsIt(route:)`` records).
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)
        #expect(await fixture.observer.entered.contains("compacts-first") == false)

        // And this path stranded nothing either, fault and stop together.
        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "cancelling a caller-driven compact() stops it too, by either route — the pump runs it as work the same way",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancellingACallerDrivenCompactStopsIt(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Warmed up for its transcript alone here: a manual compaction needs no trigger,
        // just enough content for the summarizer call to have work to do.
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await insideSummarizer.wait()

        // A manual compaction is not an answer a caller ever asked to generate, but the
        // pump runs it as its work and it runs real model work, so a stop reaches it on
        // exactly the same terms — a caller no longer has to own an enclosing `Task`
        // to get out.
        //
        // Both routes, because routing the summarizer through the session's own
        // cancellable model call *changed* how the caller's route arrives here: a
        // caller's cancellation used to propagate structurally, through the very task
        // that called `compact()`, and now has to reach an unstructured task by
        // `withTaskCancellationHandler` and the pre-flight check instead. That is the
        // most-changed behavior on this path, so it is the one least safe to leave to
        // the other route's coverage.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            compactTask.cancel()
        }
        try await Self.awaitCancelledUnwind(compactTask, sawCancellation: sawCancellation)
        #expect(await fixture.observer.toolSawCancellation)

        // And it stranded nothing on the way out, so the session still generates.
        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("a summarizer fault in a caller-driven compact() that coincides with a stop ends it as cancelled, not as the fault")
    @MainActor
    func callerCompactFaultCoincidingWithAStopIsCancelled() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // A caller compaction offers one tier only: the own model. So no later
        // tier refuses the work at its pre-flight check. Only the abandon rule
        // of the compaction can change the fault into the stop.
        let insideSummarizer = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let suspendsOn = Self.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard suspendsOn(prompt) else { return }
            insideSummarizer.signal()
            await release.wait()
            throw ProbeError.summarizerFailed
        }

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await insideSummarizer.wait()
        #expect(await session.cancel() == .requested)
        // Released by the test, so the summarizer ends with its own fault while
        // the stop is outstanding.
        release.signal()

        await #expect(throws: CancellationError.self) {
            try await compactTask.value
        }

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test("cancelling a caller-driven compact() that waits behind a running answer withdraws it at once, and no summarizer runs")
    @MainActor
    func cancellingAWaitingCallerCompactWithdrawsIt() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Not metered over the trigger, so the answer that holds the pump runs no
        // proactive compaction of its own.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)
        let actor = try #require(session as? RoutedSessionActor)

        // The pump runs this answer, so the compaction below waits in the list of
        // the pump until the answer ends.
        let holdingPrompt = "holds-the-pump"
        let insideTool = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, prompt: holdingPrompt, insideTool: insideTool)
        let answerTask = Task { try await session.respond(to: holdingPrompt) }
        await insideTool.wait()

        let compactTask = Task {
            try await session.compact(prompt: Self.compactionSummarizerPrompt, budget: Self.summarizingCompactionBudget)
        }
        await BoundedWait.spin(until: { await actor.pendingCompactions.count == 1 })
        #expect(await actor.pendingCompactions.count == 1)

        // The cancel of the caller must take the request out of the list while
        // the answer still runs. The caller does not wait for the end of the answer.
        compactTask.cancel()
        await BoundedWait.spin(until: { await actor.pendingCompactions.isEmpty })
        #expect(await actor.pendingCompactions.isEmpty)
        #expect(await actor.isPumpRunning)

        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        await #expect(throws: CancellationError.self) {
            try await compactTask.value
        }
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).isEmpty)

        fixture.hook.midAnswer = nil
        #expect(await Self.followUpAnswerCompletes(on: session, observer: fixture.observer))
    }

    @Test(
        "an answer cancelled inside its own proactive compaction re-queues the outbox events it had drained",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveCompactionRequeuesItsDrainedEvents(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // Staged after the warm-up, so this answer is the one that drains it.
        let posted = OperationEvent(
            tool: "shell", op: "run command", correlationID: "1", kind: .completed, detail: "exit 0")
        await session.outbox.post(event: posted)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        // Both routes, because losing a drained outbox is a silent data-loss bug
        // rather than a visible failure: on the caller-cancels route the re-queue
        // itself runs inside an already-cancelled task, so nothing about it may
        // depend on the task still being live.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The compaction threw before the answer ever reached the model, so nothing this
        // answer drained was delivered — and the drain must not have destroyed it.
        // The re-queue for this window is the whole reason the compaction could not
        // simply be made to throw.
        let pending = await session.outbox.pending()
        #expect(pending.events.map(\.event) == [posted])
    }

    @Test(
        "an answer cancelled inside its own proactive compaction reports no compaction, because none happened",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveCompactionReportsNoCompaction(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let recordedBefore = await fixture.recorder.events.count

        // Streamed, because ``SessionEvent/compaction(_:)`` is only observable to a
        // consumer that asked for the events of this answer.
        let delivered = DeliveredEvents()
        let answerTask = Task {
            for try await event in await session.streamEvents(to: "compacts-first") {
                await delivered.append(event)
            }
        }
        await insideSummarizer.wait()
        // Both routes, because the rule this pins — a cancelled compaction is abandoned
        // rather than degraded — is decided by a predicate that asks each route
        // separately, so its holding for one says nothing about the other.
        //
        // What the *consumer* sees is the one thing that genuinely differs by route
        // here, and it differs for a reason outside this package: cancelling a task
        // suspended in `AsyncThrowingStream.next()` **finishes** that stream rather
        // than throwing from it. So only the router-API route can be asserted with
        // ``awaitCancelledUnwind(_:sawCancellation:)``.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
            // The consumer is not what was cancelled, so it is told: the stream ends
            // by throwing the own `CancellationError` of the answer.
            try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)
        case .callerTask:
            // Cancelling the consumer terminates the stream, which cancels the task
            // the answer itself runs in — the abandoned-stream shape
            // ``abandoningAStreamRecordsTheSubmissionAsCancelled()`` pins from the other
            // side. What this route can therefore show is that the compaction let go and
            // the consumer came back at all, not an error it could never observe.
            //
            // The slowest crossing this suite makes, and the one this suite's own
            // doc takes its measurement from: the stop reaches the compaction only once
            // the cancelled consumer runs again on the shared main actor. Waited
            // on, never timed (task ^bqj719z).
            answerTask.cancel()
            try await sawCancellation.wait()
            // Safe to await, for ``followUpAnswerEvents(on:observer:prompt:)``'s reason:
            // a stream consumer's `next()` is cancellation-aware and always ends.
            _ = try? await answerTask.value
        }

        // A cancelled compaction is abandoned outright, not degraded down to the
        // next summarizer tier the way a broken summarizer is: so the consumer is
        // never told a compaction happened, and every `.compaction` this session reports
        // describes work it really did. Pinned by the router-API route — on the
        // caller-cancels one it holds trivially, since a consumer that cancelled itself
        // receives nothing further whatever the compaction went on to do.
        let compactions = await delivered.events.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.isEmpty)

        // What the caller-cancels route pins instead, and the reason it is worth
        // running: a streamed answer cut short inside its compaction is recorded like every
        // other one — a lone bodyless close — even though on that route the recording
        // runs inside an already-cancelled task. Spun for rather than read straight,
        // because a cancelled consumer returns before the producer behind it has
        // finished recording (the same ordering
        // ``abandoningAStreamRecordsTheSubmissionAsCancelled()`` waits on).
        await BoundedWait.spin(until: { await fixture.recorder.events.count == recordedBefore + 1 })
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)
    }

    @Test(
        "an answer cancelled inside its own proactive compaction leaves the transcript exactly as it was, plus one close",
        arguments: CancellationRoute.allCases)
    @MainActor
    func cancelledProactiveCompactionLeavesTheTranscriptUntouched(route: CancellationRoute) async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        let fillBefore = await session.contextFill
        let recordedBefore = await fixture.recorder.events.count

        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)

        let answerTask = Task { try await session.respond(to: "compacts-first") }
        await insideSummarizer.wait()
        // Both routes, because of the recording assertions below: on the
        // caller-cancels route the own recording of the cut-short answer runs
        // inside an already-cancelled task, which is the riskier of the two for
        // anything that must still happen on the way out.
        switch route {
        case .routerAPI:
            #expect(await session.cancel() == .requested)
        case .callerTask:
            answerTask.cancel()
        }
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // Never a half-applied compaction: a compaction records its new entries, swaps
        // `backend`, and reports its own post-compaction size as this session's fill —
        // all of it only once the summarizer has returned. An abandoned compaction does
        // none of it, so measured fill is byte-identical to what it was before.
        #expect(await session.contextFill == fillBefore)

        // Recorded like every other failed answer, and no differently for having
        // been cut short in a compaction: exactly one close, bodyless, with no `.prompt`
        // of its own because the model was never called.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 1)
        #expect(recorded.last?.kind == .response)
        #expect(recorded.last?.text == nil)

        // The session keeps working, and the abandoned compaction left the transcript it
        // was compacting alone: the *next* answer compacts for real, and its compaction measures
        // exactly the untouched warm-up transcript. Had the cancelled compaction swapped
        // `backend` for a compacted one, this would measure the smaller, compacted size —
        // which is what makes this an assertion about `backend` itself and not only
        // about the ordering inside `compaction`. The hook is cleared first, or that next
        // compaction would suspend in the summarizer all over again.
        fixture.hook.midAnswer = nil
        let followUp = try #require(await Self.followUpAnswerEvents(on: session, observer: fixture.observer))
        let untouchedSize = try characterTokenCounter.count(Transcript(entries: Self.warmUpEntries()))
        let compactions = followUp.compactMap { event -> CompactionResult? in
            guard case .compaction(let result) = event else { return nil }
            return result
        }
        #expect(compactions.map(\.tokensBefore) == [untouchedSize])
    }

    @Test("cancelling an answer inside its reactive compact-and-retry-once compaction stops the retry, leaving one close")
    @MainActor
    func cancellingTheReactiveCompactionStopsTheRetry() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        // Unmetered, so the proactive gate never fires and the only compaction in play is
        // the one the own context overflow of this answer triggers.
        let session = try await Self.makeCompactionTriggeredSession(
            fixture, budget: Self.summarizingCompactionBudget, metersTriggeringFill: false)

        let recordedBefore = await fixture.recorder.events.count
        let insideSummarizer = AsyncSemaphore(value: 0)
        let sawCancellation = Self.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Self.firstSummarizerCall(), insideTool: insideSummarizer)
        // Composed on top of the summarizer suspension rather than replacing it: this answer
        // has to overflow *and then* suspend inside the compaction that overflow triggers.
        let suspendInSummarizer = fixture.hook.midAnswer
        // The summarizer call renders the whole live context, the own prompt of
        // the failed submission last, so its prompt also ends with the prompt of
        // the answer. Only a call that is not the summarizer's is the own call of
        // the answer.
        fixture.hook.midAnswer = { prompt in
            guard !Self.isSummarizerCall(prompt), prompt.hasSuffix(Self.overflowingCompactionPrompt) else {
                try await suspendInSummarizer?(prompt)
                return
            }
            throw LanguageModelError.contextSizeExceeded(
                .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow"))
        }

        let answerTask = Task {
            try await session.respond(to: Self.overflowingCompactionPrompt)
        }
        await insideSummarizer.wait()
        #expect(await session.cancel() == .requested)
        try await Self.awaitCancelledUnwind(answerTask, sawCancellation: sawCancellation)

        // The retry never ran: the model saw this answer exactly once, and what the
        // caller gets is the cancellation rather than the overflow it was recovering
        // from.
        #expect(
            await fixture.observer.entered.filter {
                !Self.isSummarizerCall($0) && $0.hasSuffix(Self.overflowingCompactionPrompt)
            }.count == 1)

        // One close, not two: the failed attempt's own, recorded before the compaction
        // started. The retry that would have written the second never happened, and
        // the cancelled compaction adds none of its own.
        let recorded = await fixture.recorder.events
        #expect(recorded.count == recordedBefore + 2)
        #expect(Array(recorded.map(\.kind).suffix(2)) == [.prompt, .response])
        #expect(recorded.last?.text == nil)
    }

    @Test("a compaction with no cancellation outstanding makes its one call and runs its answer exactly as before")
    @MainActor
    func compactionWithNoStopOutstandingIsUnaffected() async throws {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let fixture = try await Self.makeFixture(cacheDir: dir)
        let session = try await Self.makeCompactionTriggeredSession(fixture, budget: Self.summarizingCompactionBudget)

        // No hook installed and no stop requested: the cancellation boundary around
        // the summarizer call must cost the compaction nothing.
        var collected: [SessionEvent] = []
        for try await event in await session.streamEvents(to: "compacts-uncancelled") {
            collected.append(event)
        }
        let events = eventsInsideAnswerFrame(collected)
        #expect(collected.answers.count == 1)
        #expect(collected.answerFailures.isEmpty)

        guard case .compaction(let result) = events.first else {
            Issue.record("expected the first event of the answer to be .compaction, got \(String(describing: events.first))")
            return
        }
        let untouchedSize = try characterTokenCounter.count(Transcript(entries: Self.warmUpEntries()))
        #expect(result.tokensBefore == untouchedSize)
        #expect(await fixture.observer.entered.filter(Self.isSummarizerCall).count == 1)

        // And the own work of the answer ran normally straight after the compaction.
        let streamedText = events.compactMap { event -> String? in
            guard case .textDelta(let text) = event else { return nil }
            return text
        }.joined()
        #expect(streamedText == "ok-compacts-uncancelled")
    }
}

