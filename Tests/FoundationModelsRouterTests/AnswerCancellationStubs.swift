import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// The stubs of ``AnswerCancellationTests``: the observers, the backend
/// that runs ``AnswerHook/midAnswer`` inside its model call, and the
/// container and loader that vend it. No network, no GPU.
extension AnswerCancellationTests {
    // MARK: - Answer observability

    /// Records which answers entered and left the model and whether a tool
    /// running inside the model call ever observed cancellation, so
    /// propagation past `body` is asserted rather than inferred.
    actor AnswerObserver {
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
    actor DeliveredEvents {
        private(set) var events: [SessionEvent] = []

        func append(_ event: SessionEvent) {
            events.append(event)
        }
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
    /// Properly `Sendable`, like ``StubSessionBackend``, because on this backend
    /// the transcript really is shared: the streaming path
    /// produces from a task of its own, and a submission cancelled mid-stream stops
    /// consuming (and goes on to read ``transcriptEntries()`` for its diff) while
    /// that producer is still live. Whether the two actually overlap depends on
    /// what the installed hook does about cancellation, which is no basis for a
    /// data-race argument — so ``entries`` is behind a ``Mutex`` and the question
    /// does not arise.
    final class HookedSessionBackend: LanguageModelSessionBackend {
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
    final class HookedLLMContainer: LoadedLLMContainer {
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
    struct StubEmbeddingContainer: LoadedEmbeddingContainer {
        let dimension: Int
        func embed(texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [Float](repeating: 0.5, count: dimension) }
        }
    }

    // MARK: - Stubs

    struct StubProbe: MachineProbe {
        let chip: String
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64
    }

    struct StubMetadataSource: MetadataSource {
        let raw: RawRepoMetadata
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
    }

    /// A ``ModelLoader`` returning the identical, test-supplied container for
    /// every generation slot — so every session in a test shares one model. No
    /// download, no GPU.
    struct StubModelLoader: ModelLoader {
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
}
