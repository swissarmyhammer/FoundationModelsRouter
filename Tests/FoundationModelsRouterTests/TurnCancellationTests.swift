import Foundation
import FoundationModels
import Operations
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/cancelCurrentTurn()``: cancelling the turn already
/// **in flight**, as opposed to ``RoutedSession/cancel(_:)``'s queue-side
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

    /// Failures a test's own stand-in tool raises to mark a path that must never
    /// be taken.
    private enum ProbeError: Error, Equatable {
        /// The overflow retry re-entered the model even though the turn had
        /// already been cancelled.
        case modelReenteredAfterCancellation
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

        init(
            hook: TurnHook,
            observer: TurnObserver,
            appendsPromptBeforeToolCall: Bool,
            entries: [Transcript.Entry] = []
        ) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
            self.transcript = Mutex(entries)
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

        /// No usage is tracked here — this suite exercises cancellation, not
        /// metering.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }

        func makeFork() -> any LanguageModelSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall, entries: entries)
        }
    }

    /// A ``LoadedLLMContainer`` vending ``HookedSessionBackend``s wired to one
    /// shared hook and observer.
    ///
    /// Immutable after construction, so it is plainly `Sendable`: every test here
    /// observes turns through the shared ``TurnObserver`` and the recorder rather
    /// than by reaching for a particular session's backend.
    private final class HookedLLMContainer: LoadedLLMContainer {
        private let hook: TurnHook
        private let observer: TurnObserver
        private let appendsPromptBeforeToolCall: Bool

        init(hook: TurnHook, observer: TurnObserver, appendsPromptBeforeToolCall: Bool) {
            self.hook = hook
            self.observer = observer
            self.appendsPromptBeforeToolCall = appendsPromptBeforeToolCall
        }

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: [])
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeHookedBackend(entries: Array(transcript))
        }

        private func makeHookedBackend(entries: [Transcript.Entry]) -> HookedSessionBackend {
            HookedSessionBackend(
                hook: hook, observer: observer, appendsPromptBeforeToolCall: appendsPromptBeforeToolCall, entries: entries)
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

    /// The one live model handle every session in a test is vended from, plus the
    /// container, observer, and hook wired behind it.
    private struct Fixture {
        let observer: TurnObserver
        let hook: TurnHook
        let recorder: InMemoryRecorder

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
        return Fixture(observer: observer, hook: hook, recorder: recorder, profile: profile)
    }

    /// Installs a mid-turn hook that parks the turn named `prompt` inside a tool
    /// call which *observes* cancellation: it suspends on a semaphore released by
    /// its own cancellation handler, then re-checks cancellation and reports what
    /// it saw — the shape a real MCP tool awaiting a reply has, rather than a poll
    /// of `Task.isCancelled`.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - prompt: The turn's own prompt text to park on, matched as a suffix of
    ///     what the backend actually receives: a turn that drained outbox events
    ///     is handed those events as a preamble followed by its own prompt (see
    ///     ``RoutedSessionActor/composedPrompt(pendingEvents:prompt:)``), so an
    ///     equality check here would silently never fire for exactly the turns the
    ///     outbox tests park. Every other turn runs straight through.
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
        prompt: String,
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
            guard turnPrompt.hasSuffix(prompt) else { return }
            guard let humanWait else {
                try await park()
                return
            }
            try await humanWait.awaitingUser(park)
        }
        return parked
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
        await spin(until: { await observer.toolSawCancellation })
        guard await observer.toolSawCancellation else {
            Issue.record("cancellation never reached the tool call running inside the model call")
            parked.signal()
            turnTask.cancel()
            _ = try? await turnTask.value
            return
        }
        await #expect(throws: CancellationError.self) {
            try await turnTask.value
        }
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
        #expect(await session.cancel(queued) == .alreadySent)
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
        #expect(await session.cancel(id) == .applied)

        // Nothing dispatched, nothing generated, nothing recorded — the
        // additive in-flight primitive left the queue-side one exactly as it was.
        #expect(try await session.dispatchNextPrompt() == nil)
        #expect(await fixture.observer.entered.isEmpty)
        #expect(await fixture.recorder.events.isEmpty)
        #expect(await session.pendingPrompts().isEmpty)
    }
}
