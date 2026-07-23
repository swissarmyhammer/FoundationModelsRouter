import Foundation
import FoundationModels
import MLX
import MLXEmbedders
import MLXFoundationModels
import MLXLLM
import MLXLMCommon

// The MLX container types are the live loaded handles. They are `final class …:
// Sendable`, so conforming them to the router's marker protocols lets
// ``LiveModelLoader`` vend real generation and embedding through the same
// orchestration the unit suite drives with stubs. These are the milestone-7
// live seams: ``MLXFoundationModelsContainer`` runs the real `LanguageModelSession`
// (`FoundationModels`) pipeline over an `MLXLanguageModel` conformance, and
// ``LiveEmbeddingContainer`` wraps `MLXEmbedders` with a probed dimension.
//
// **No `MLXLMCommon.ChatSession` and no hand-rolled generation loop.** The
// session surface every generation call runs through is Apple's own
// `LanguageModelSession`, backed by `MLXLanguageModel` (`MLXFoundationModels`,
// our `swissarmyhammer/mlx-swift-lm` fork's `mlx-foundationmodels` branch,
// tracking upstream PR ml-explore/mlx-swift-lm#334). Guided (JSON-Schema)
// generation runs through `LanguageModelSession.respond(to:schema:)`, which
// invokes `MLXLanguageModel`'s own `Executor` — the xgrammar-constrained decode
// (`MLXGuidedGeneration`) happens *underneath* the `LanguageModel` conformance,
// invoked by FoundationModels, not called directly here. See plan.md's
// "Backends" and "Guided generation" sections.

/// The default token budget for the live generation paths.
///
/// Applies when a caller does not supply its own `maxTokens`, so a routed
/// turn cannot run away. Plain and guided generation share the same default —
/// there is no principled reason for guided decode to get a different ceiling.
private let defaultMaxTokens = 8192

/// The live ``LoadedLLMContainer``.
///
/// Wraps an `MLXLanguageModel` — the `FoundationModels.LanguageModel` protocol
/// conformance `MLXFoundationModels` provides over a resident MLX
/// `ModelContainer` — and manufactures the ``LanguageModelSessionBackend``
/// every generation call actually runs through.
///
/// This container no longer invokes generation itself (see
/// ``LoadedLLMContainer/makeSession(instructions:)``); ``makeSession(instructions:)``
/// below vends a ``MLXFoundationModelsSessionBackend`` that drives a real
/// `LanguageModelSession` built over ``model``, and
/// ``makeSession(transcript:)`` vends one seeded from an existing transcript
/// instead — the factory a restored session tree rebuilds from. Constructing
/// a session is cheap either way: `MLXLanguageModel` is a small `Sendable`
/// value whose actual weights are loaded once and cached by its own
/// process-global cache, keyed by model id — building a session over it does
/// not reload anything.
struct MLXFoundationModelsContainer: LoadedLLMContainer, Sendable {
    /// The `LanguageModel` conformance wrapping this slot's resident MLX model.
    let model: MLXLanguageModel

    /// The raw `FoundationModels.LanguageModel` this container wraps — the
    /// seam ``RoutedModel/makeLanguageModel()`` wraps in a
    /// ``RecordingLanguageModel`` passthrough handle. `MLXLanguageModel` is a
    /// small `Sendable` value (see the type-level doc comment above), so
    /// exposing it here reloads nothing.
    var languageModel: any FoundationModels.LanguageModel { model }

    /// Manufactures a live session backend over ``model``.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Manufactures a live session backend over ``model``, with `tools`
    /// threaded to the underlying `LanguageModelSession` so the model can call
    /// them.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools the model can call during this session.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    func makeSession(instructions: String?, tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        let session = LanguageModelSession(model: model, tools: tools, instructions: instructions)
        return MLXFoundationModelsSessionBackend(
            session: session, model: model, instructions: instructions, tools: tools)
    }

    /// Manufactures a live session backend seeded from an existing transcript.
    ///
    /// Builds the new `LanguageModelSession` directly over `transcript` via
    /// `LanguageModelSession(model:tools:transcript:)` — the identical public
    /// initializer ``MLXFoundationModelsSessionBackend/makeFork()`` calls to
    /// seed a forked session from a parent's accumulated transcript. Unlike a
    /// fork, this factory has no live parent backend to copy `instructions`
    /// from (`transcript` may have come from disk, long after any originating
    /// session existed), so the new backend's retained ``instructions`` are
    /// derived from `transcript`'s own `.instructions` entry when present —
    /// the only place a transcript carries them forward, since there is no
    /// `LanguageModelSession` initializer that accepts both `transcript:` and
    /// `instructions:` together.
    ///
    /// - Parameter transcript: The transcript to seed the new session from.
    /// - Returns: A new ``MLXFoundationModelsSessionBackend`` a vended
    ///   ``RoutedSession`` drives for its lifetime.
    func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend {
        let session = LanguageModelSession(model: model, tools: [], transcript: transcript)
        return MLXFoundationModelsSessionBackend(
            session: session,
            model: model,
            instructions: TranscriptDiffer.leadingInstructionsText(of: transcript)
        )
    }
}

/// The live ``LanguageModelSessionBackend``.
///
/// Wraps a real `LanguageModelSession` — held for this backend's entire
/// lifetime, not rebuilt per call — so it accumulates conversation state (the
/// transcript) across calls the way a real multi-turn chat does: a second
/// ``respond(to:maxTokens:)`` sees the first turn's content in context.
///
/// `@unchecked Sendable`: `LanguageModelSession` is itself `@unchecked
/// Sendable` (confirmed: `extension FoundationModels::LanguageModelSession :
/// @unchecked Swift::Sendable` in the macOS 27 SDK interface), which only
/// certifies the type as safe to *hold* across an isolation boundary, not
/// safe for *concurrent* calls. Concurrent access to this backend's
/// ``session`` is safe in practice because every call runs inside
/// ``RoutedSessionActor``'s `serialGate` — an `AsyncSemaphore` at value 1,
/// shared with the session's forks — so at most one generation call against a
/// given model's family of sessions is ever in flight at a time; this
/// backend's session is never actually touched from two tasks concurrently
/// despite being a reference type.
final class MLXFoundationModelsSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The `LanguageModel` conformance ``makeFork()`` builds its forked session
    /// over, seeded from this backend's own accumulated transcript.
    private let model: MLXLanguageModel

    /// The live session every call on this backend runs through, accumulating
    /// conversation state (the transcript) for this backend's lifetime.
    private let liveSession: LanguageModelSession

    /// The system instructions ``liveSession`` was created with, or `nil`.
    ///
    /// `LanguageModelSession` exposes no `instructions` accessor of its own —
    /// the only trace of them is the `Transcript.Entry.instructions` case
    /// `liveSession.transcript` carries as its first entry when instructions
    /// were supplied. Stored here explicitly (rather than re-derived from the
    /// transcript on demand) so ``makeFork()`` can hand it straight to the
    /// forked backend, keeping every backend in a fork chain able to report
    /// the instructions it was seeded with without re-parsing transcript
    /// entries.
    private let instructions: String?

    /// The tools ``liveSession`` was created with.
    ///
    /// Stored (rather than only baked into `liveSession`) so ``makeFork()``
    /// (called with no fork-then-connect tool list of its own to supply) can
    /// hand these identical instances to the forked session, mirroring how
    /// ``instructions`` is retained here for the same reason — there is no
    /// way to read a `LanguageModelSession`'s tools back off it.
    /// ``makeFork(tools:)`` threads a caller-supplied list instead, so this
    /// field only ever matters to the zero-argument overload.
    private let tools: [any FoundationModels.Tool]

    /// Test-only accessor onto ``liveSession``, for `@testable import` in the
    /// gated integration suite (e.g. asserting `transcript.count` grows across
    /// turns, or matches a fork's parent at fork time). Deliberately not part
    /// of ``LanguageModelSessionBackend`` — this is test-only surface, not
    /// something a caller of the protocol should drive.
    internal var session: LanguageModelSession { liveSession }

    /// Creates a backend over an already-constructed session and the model it
    /// was built over. `model` is kept alongside so ``makeFork()`` can build a
    /// forked session of the same type, continuing this session's transcript.
    ///
    /// - Parameters:
    ///   - session: The live `LanguageModelSession` this backend drives.
    ///   - model: The `LanguageModel` conformance `session` was built over.
    ///   - instructions: The system instructions `session` was created with,
    ///     or `nil`. Stored so ``makeFork()`` can propagate it to the forked
    ///     backend; see ``instructions``.
    ///   - tools: The tools `session` was created with. Stored so
    ///     ``makeFork()`` can propagate them to the forked backend; see
    ///     ``tools``. Defaults to none.
    init(
        session: LanguageModelSession,
        model: MLXLanguageModel,
        instructions: String? = nil,
        tools: [any FoundationModels.Tool] = []
    ) {
        self.liveSession = session
        self.model = model
        self.instructions = instructions
        self.tools = tools
    }

    /// Generates a complete text response through ``liveSession``.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await respond(to: prompt, schema: nil, maxTokens: maxTokens)
    }

    /// Runs ``liveSession`` and returns its response content, constrained to
    /// `schema` when one is given.
    ///
    /// Shared by ``respond(to:maxTokens:)`` and the `.jsonSchema` case of
    /// ``respond(to:following:maxTokens:)``: both call the matching
    /// `session.respond` overload with the same prompt and options, and differ
    /// only in whether a schema is supplied and in how the resulting content is
    /// stringified.
    private func respond(
        to prompt: String,
        schema: GenerationSchema?,
        maxTokens: Int?
    ) async throws -> String {
        let options = GenerationOptions(maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        guard let schema else {
            let response = try await liveSession.respond(to: prompt, options: options)
            return response.content
        }
        let response = try await liveSession.respond(to: prompt, schema: schema, options: options)
        return response.content.jsonString
    }

    /// Streams a text response through ``liveSession``.
    ///
    /// Adapts its snapshot-based stream into this seam's delta (fragment)
    /// contract.
    ///
    /// **Verified, not assumed** (per the FoundationModels v2 SDK's
    /// `LanguageModelSession.ResponseStream`): each element the stream yields is
    /// a `Snapshot` whose `content` is the *cumulative* response text so far
    /// (`Content.PartiallyGenerated`, `= String` for `Content == String`) — not
    /// a per-token delta. `RoutedSession/streamResponse(to:)`'s documented
    /// contract is a stream of *fragments* a caller accumulates (mirroring the
    /// prior `ChatSession`-backed behavior), so this yields only the new suffix
    /// of each snapshot, computed against the previous one.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        let options = GenerationOptions(maximumResponseTokens: maxTokens ?? defaultMaxTokens)
        return AsyncThrowingStream { continuation in
            let task = Task {
                await self.pumpStream(prompt: prompt, options: options, into: continuation)
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Drives ``liveSession``'s cumulative-snapshot stream to completion.
    ///
    /// Forwards each snapshot's new suffix into `continuation` and finishes
    /// (or fails) it when the underlying stream ends.
    ///
    /// Extracted out of ``streamResponse(to:maxTokens:)`` so that method's
    /// `AsyncThrowingStream` closure only has to spawn a `Task` and await this
    /// helper — the do/catch, for-loop, and delta-check live here instead of
    /// stacked five levels deep inside the stream-building closure.
    private func pumpStream(
        prompt: String,
        options: GenerationOptions,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        var previous = ""
        do {
            for try await snapshot in liveSession.streamResponse(to: prompt, options: options) {
                let current = snapshot.content
                let delta = Self.suffix(of: current, after: previous)
                if !delta.isEmpty {
                    continuation.yield(delta)
                }
                previous = current
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// The new suffix `current` has beyond `previous`.
    ///
    /// Assumes `current` extends `previous` the way a cumulative streaming
    /// snapshot does.
    ///
    /// - Returns: The whole of `current` if it does not have `previous` as a
    ///   prefix — a defensive fallback for a non-monotonic snapshot, not
    ///   expected in practice — otherwise just the new suffix.
    private static func suffix(of current: String, after previous: String) -> String {
        guard current.hasPrefix(previous) else { return current }
        return String(current.dropFirst(previous.count))
    }

    /// Generates a grammar-constrained response through ``liveSession``.
    ///
    /// ``Grammar/jsonSchema(_:)`` compiles the caller's JSON Schema source into
    /// a `GenerationSchema` via ``RuntimeJSONSchemaConverter`` (see its
    /// documentation for why `GenerationSchema`'s own `Codable` conformance
    /// cannot be used for this) and drives `LanguageModelSession.respond(to:schema:)`
    /// — the xgrammar-constrained decode this produces runs entirely inside
    /// `MLXLanguageModel`'s `Executor`, invoked by FoundationModels, never by a
    /// loop of our own. ``Grammar/ebnf(_:)`` has no equivalent entry point on
    /// `LanguageModelSession` (which only accepts a typed `schema:` parameter,
    /// never a raw grammar string) and is not supported under this backend —
    /// see ``GuidedRequestError/ebnfNotSupportedByLanguageModelSession``.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try grammar.validateForXGrammar()
        switch grammar {
        case .ebnf:
            throw GuidedRequestError.ebnfNotSupportedByLanguageModelSession
        case .jsonSchema(let schemaText):
            let schema = try RuntimeJSONSchemaConverter.compile(schemaText)
            return try await respond(to: prompt, schema: schema, maxTokens: maxTokens)
        }
    }

    /// Vends a fresh backend seeded from this session's accumulated transcript.
    ///
    /// `LanguageModelSession.init(model:tools:transcript:)` is the real
    /// transcript-continuation primitive the FoundationModels v2 SDK provides
    /// (see plan.md's "Sessions & KV cache" section for why this is a
    /// correctness primitive, not a cheap-prefix-reuse one, against the pinned
    /// `mlx-swift-lm` dependency): the forked session begins holding every
    /// entry ``liveSession``'s transcript has accumulated so far — including
    /// the `Transcript.Entry.instructions` entry the parent's system
    /// instructions were recorded as, if any — then diverges independently as
    /// each session's own further turns append to its own transcript.
    ///
    /// ``instructions`` is threaded into the new backend alongside the
    /// transcript-seeded session, so the fork reports the same instructions
    /// the parent was created with (there is no `LanguageModelSession`
    /// initializer that accepts both `transcript:` and `instructions:`
    /// together — the transcript's own `.instructions` entry is what actually
    /// carries them forward into generation). Delegates to
    /// ``makeFork(tools:)`` with ``tools`` (this backend's own, unchanged) so
    /// the forked session's model can still call whatever tools the parent
    /// could — the only behavior a direct `makeFork()` call (bypassing
    /// ``RoutedSessionActor/fork(workingDirectory:)``) can ask for, since it
    /// has no fork-then-connect tool list of its own to supply.
    func makeFork() -> any LanguageModelSessionBackend {
        makeFork(tools: tools)
    }

    /// Produces a new backend seeded from this session's accumulated
    /// transcript, with `tools` threaded to the forked `LanguageModelSession`
    /// instead of this backend's own.
    ///
    /// This is the overload ``RoutedSessionActor/fork(workingDirectory:)``
    /// actually calls, with its own fork-then-connect composed child tool
    /// list (each of the parent's true originals forked via
    /// ``ForkableTool/forked()`` where applicable, then reconnected to the
    /// child's own outbox via ``EventEmittingTool/connecting(_:)``) — so the
    /// live model backing the fork calls the child's own tool instances,
    /// wired to the child's own outbox, rather than silently carrying
    /// forward whatever instances this backend was built with (which would
    /// still be wired to an ancestor's outbox, defeating the fork-then-connect
    /// composition's whole point for any tool the model actually invokes).
    func makeFork(tools: [any FoundationModels.Tool]) -> any LanguageModelSessionBackend {
        let forkedSession = LanguageModelSession(model: model, tools: tools, transcript: liveSession.transcript)
        return MLXFoundationModelsSessionBackend(
            session: forkedSession, model: model, instructions: instructions, tools: tools)
    }

    /// Returns ``liveSession``'s current transcript, in order.
    ///
    /// See the protocol requirement's doc comment
    /// (``LanguageModelSessionBackend/transcriptEntries()``) for the
    /// serial-gate precondition this call must be made under.
    func transcriptEntries() -> [FoundationModels.Transcript.Entry] {
        Array(liveSession.transcript)
    }

    /// Returns ``liveSession``'s cumulative token usage.
    ///
    /// See the protocol requirement's doc comment
    /// (``LanguageModelSessionBackend/usageTokenCounts()``) for the
    /// serial-gate precondition this call must be made under.
    ///
    /// **Empirical status: unverified in this environment.** `LanguageModelSession.usage`
    /// (`Usage{input: Input{totalTokenCount, cachedTokenCount}, output:
    /// Output{totalTokenCount, reasoningTokenCount}}`) is confirmed present in
    /// the macOS 27 `FoundationModels` swiftinterface, and the gated
    /// integration suite (`LanguageModelSessionBackendIntegrationTests.secondTurnReusesFirstTurnsKVCache`,
    /// task 070qw7z) already asserts `usage.input.totalTokenCount > 0` and
    /// `usage.output.totalTokenCount > 0` against a real model as a hard,
    /// unweakened requirement — but that suite needs a GPU and network access
    /// this sandbox does not have, so it has never actually run here; it only
    /// ever reports "skipped". Whether `MLXLanguageModel`'s `Executor`
    /// populates real, non-zero totals for `usage.input`/`usage.output` (as
    /// opposed to leaving them at zero) has therefore **not been empirically
    /// confirmed in this environment** — this doc comment states that
    /// honestly rather than claiming verification that never happened. This
    /// implementation returns the SDK's real value regardless — never a
    /// fabricated zero or a preemptive `nil` for lack of proof — so it is
    /// already correct once the executor does populate real counts, and the
    /// gated integration suite above is where the populated-vs-zero question
    /// gets an actual answer, on real hardware.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        let usage = liveSession.usage
        return (usage.input.totalTokenCount, usage.output.totalTokenCount)
    }
}

/// The live embedding container.
///
/// Wraps a loaded `EmbedderModelContainer` and the embedding ``dimension``
/// probed once at load, so the router's synchronous
/// ``LoadedEmbeddingContainer/dimension`` accessor reports a real value and
/// ``embed(texts:)`` runs the real `MLXEmbedders` pooling pipeline.
///
/// The wrapper exists because `EmbedderModelContainer` exposes its model only
/// through an async `perform` closure, so the dimension is not knowable
/// synchronously from the raw container; ``LiveModelLoader/loadEmbedder(ref:slot:reporting:)``
/// probes it once and stores it here. Embedding does not go through
/// `LanguageModelSession` — `MLXEmbedders` has no `FoundationModels.LanguageModel`
/// surface, so this stays on the direct `MLXEmbedders` pipeline (see plan.md's
/// "Backends" section).
final class LiveEmbeddingContainer: LoadedEmbeddingContainer, Sendable {
    /// The loaded MLX embedder container the computation runs through.
    private let container: EmbedderModelContainer

    /// The length of every embedding vector this model produces, probed at load.
    let dimension: Int

    /// Creates a live embedding container over a loaded MLX container and its probed embedding dimension.
    init(container: EmbedderModelContainer, dimension: Int) {
        self.container = container
        self.dimension = dimension
    }

    /// Embeds each input into a ``dimension``-length, L2-normalized vector through the real `MLXEmbedders` pipeline.
    func embed(texts: [String]) async throws -> [[Float]] {
        try await Self.embed(texts: texts, in: container)
    }

    /// The shared embedding computation.
    ///
    /// Tokenizes, pads to the batch max, runs the model, pools (normalized),
    /// and reads the vectors back to `[[Float]]`. Static so ``LiveModelLoader``
    /// can probe the dimension at load without a wrapper instance. Mirrors the
    /// fork's own `MLXEmbedders` usage example.
    ///
    /// - Parameters:
    ///   - texts: The strings to embed.
    ///   - container: The embedder model container to use.
    /// - Returns: One vector per input string.
    /// - Throws: If embedding computation fails.
    static func embed(texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return await container.perform { context in
            let tokenizer = context.tokenizer
            let encoded = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = encoded.reduce(into: 1) { $0 = max($0, $1.count) }
            let padded = stacked(
                encoded.map { tokens in
                    MLXArray(
                        tokens
                            + Array(
                                repeating: tokenizer.eosTokenId ?? 0,
                                count: maxLength - tokens.count
                            )
                    )
                }
            )
            let mask = padded .!= (tokenizer.eosTokenId ?? 0)
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(
                padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask
            )
            let pooled = context.pooling(output, normalize: true, applyLayerNorm: true)
            pooled.eval()
            return pooled.map { $0.asArray(Float.self) }
        }
    }
}

/// A failure constructing or invoking a ``ModelLoader``.
public enum ModelLoaderError: Error, Equatable {
    /// No real loader was configured.
    ///
    /// The ``Router`` was built without a ``LiveModelLoader`` (which requires
    /// a `Downloader` and `TokenizerLoader`) and without an injected stub. See
    /// ``UnconfiguredModelLoader``.
    case notConfigured
}

/// The live ``ModelLoader``.
///
/// Downloads weights from a Hugging Face-compatible source and materializes
/// an ``MLXFoundationModelsContainer`` for generation (backed by
/// `MLXLanguageModel` + `LanguageModelSession`) and a
/// ``LiveEmbeddingContainer`` for embedding.
///
/// This fork of `mlx-swift-lm` intentionally does **not** bundle a default Hub
/// client — integration packages "inject their own `Downloader` and
/// `TokenizerLoader`" (the `MLXHuggingFace` `#hubDownloader()` /
/// `#huggingFaceTokenizerLoader()` macros pull in `swift-huggingface` /
/// `swift-transformers`, which are not in this package's dependency graph). So
/// ``LiveModelLoader`` is the real wiring over the **core** loader API and takes
/// the `Downloader` and `TokenizerLoader` as construction parameters; the
/// integration suite (milestone 7) supplies concrete Hub-backed instances.
///
/// Generation models load through `MLXFoundationModels.MLXLanguageModel`, which
/// wraps `MLXLMCommon`'s `loadModelContainer` (resolving the configuration
/// against the registered `MLXLLM` factories) and caches the resident
/// `ModelContainer` itself, keyed by model id; embedding models load through
/// `MLXEmbedders`' `EmbedderModelFactory` directly. Both map the Foundation
/// `Progress` into ``DownloadProgress``.
public struct LiveModelLoader: ModelLoader {
    /// The source that fetches model and tokenizer files.
    private let downloader: any Downloader

    /// The factory that loads a tokenizer from downloaded files.
    private let tokenizerLoader: any TokenizerLoader

    /// Resolves a model identifier to its on-disk weights directory.
    ///
    /// Passed through to `MLXLanguageModel` for its availability checks
    /// (`modelExistsOnDisk()`, free-disk-space checks) — **not** consulted by
    /// the load path itself, which always goes through `load`/`downloader`
    /// below. Defaults to a harmless temporary-directory stub for callers that
    /// don't need those availability checks to resolve real paths.
    private let weightsLocation: @Sendable (String) -> URL

    /// Creates a live loader over an injected downloader and tokenizer loader.
    ///
    /// - Parameters:
    ///   - downloader: The source that fetches model and tokenizer files (e.g. a
    ///     Hub client supplied by the integration suite).
    ///   - tokenizerLoader: The factory that loads a tokenizer from those files.
    ///   - weightsLocation: Resolves a model id to its on-disk weights
    ///     directory, for `MLXLanguageModel`'s availability checks. Defaults to
    ///     a stub that never resolves a real path — pass the Hub cache's real
    ///     repo-directory resolver (e.g. `HubCache.repoDirectory(repo:kind:)`)
    ///     when those checks matter.
    public init(
        downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        weightsLocation: @escaping @Sendable (String) -> URL = { _ in
            FileManager.default.temporaryDirectory
        }
    ) {
        self.downloader = downloader
        self.tokenizerLoader = tokenizerLoader
        self.weightsLocation = weightsLocation
    }

    /// Downloads and loads a generation model into an ``MLXFoundationModelsContainer``.
    ///
    /// Builds an `MLXLanguageModel` over the model's configuration and this
    /// loader's downloader/tokenizer loader, then forces eager loading now
    /// (`MLXLanguageModel` itself otherwise defers loading until first
    /// inference), matching the router's residency model: `preload()`s and
    /// holds every slot resident for the profile's lifetime (see plan.md's
    /// "Residency" section).
    ///
    /// - Parameters:
    ///   - ref: The model reference to download and load.
    ///   - slot: The slot the model is being loaded for.
    ///   - context: The context length to size the model for.
    ///   - reporting: The byte-based download-progress callback, invoked as
    ///     weights stream in.
    /// - Returns: The loaded generation container.
    /// - Throws: If the download or MLX container load fails.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        let downloader = self.downloader
        let tokenizerLoader = self.tokenizerLoader
        let modelConfiguration = configuration(for: ref)
        let model = MLXLanguageModel(
            configuration: modelConfiguration,
            capabilities: [.guidedGeneration, .toolCalling],
            weightsLocation: weightsLocation,
            load: { configuration, mlxProgressHandler in
                try await loadModelContainer(
                    from: downloader,
                    using: tokenizerLoader,
                    configuration: configuration,
                    progressHandler: { progress in
                        // Forward to both: `MLXLanguageModel`'s own global
                        // `MLXDownloadProgress` broadcast (its usual signal for
                        // e.g. a SwiftUI observer bound to `.shared`) and this
                        // router's own byte-based progress plumbing, which is
                        // what `Router`/`ResolutionProgress` actually consume.
                        mlxProgressHandler(progress)
                        Self.handler(reporting: reporting)(progress)
                    }
                )
            }
        )
        _ = try await model.loadContainer()
        return MLXFoundationModelsContainer(model: model)
    }

    /// Downloads and loads an embedding model.
    ///
    /// Wraps it in a ``LiveEmbeddingContainer`` with its embedding dimension
    /// probed once now. `EmbedderModelContainer` only exposes its model
    /// through an async closure, so the dimension is not available
    /// synchronously; a single probe embedding establishes it (and warms the
    /// model) before the container is vended.
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference to download and load.
    ///   - slot: The slot the model is being loaded for.
    ///   - reporting: The byte-based download-progress callback, invoked as
    ///     weights stream in.
    /// - Returns: The loaded ``LiveEmbeddingContainer`` with its probed dimension.
    /// - Throws: If the download, MLX container load, or dimension probe fails.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        let container = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: configuration(for: ref),
            progressHandler: Self.handler(reporting: reporting)
        )
        let probe = try await LiveEmbeddingContainer.embed(texts: ["dimension probe"], in: container)
        return LiveEmbeddingContainer(container: container, dimension: probe.first?.count ?? 0)
    }

    /// Builds the MLX `ModelConfiguration` for a model ref.
    ///
    /// Pins the ref's revision or falls back to ``defaultRevision`` — shared
    /// by the generation and embedding load paths.
    private func configuration(for ref: ModelRef) -> ModelConfiguration {
        ModelConfiguration(id: ref.repo, revision: ref.revision ?? Self.defaultRevision)
    }

    /// Warms a loaded container.
    ///
    /// `loadLLM`/`loadEmbedder` already materialize weights eagerly (an
    /// `MLXLanguageModel`'s `loadContainer()` is forced there; the embedder's
    /// container loads synchronously in `loadEmbedder`), so this hook is a
    /// no-op seam for any future explicit warm-up (e.g. a throwaway forward
    /// pass beyond weight materialization).
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: If warm-up fails.
    public func preload(container: any LoadedModelContainer) async throws {}

    /// Evicts a loaded container, freeing the GPU memory its weights hold.
    ///
    /// Routed through ``MLXFoundationModelsContainer/model``'s real
    /// `MLXLanguageModel.evict()` when the container is a live generation
    /// container (dropping it from `MLXLanguageModel`'s process-global cache,
    /// so a subsequent load reloads from the on-disk snapshot); a no-op for any
    /// other container (e.g. the embedding container, which has no equivalent
    /// eviction hook today).
    ///
    /// - Parameter container: The container to evict.
    public func evict(container: any LoadedModelContainer) async {
        guard let generation = container as? MLXFoundationModelsContainer else { return }
        await generation.model.evict()
    }

    /// The revision used when a ``ModelRef`` does not pin one.
    private static let defaultRevision = "main"

    /// Maps a single Foundation `Progress` snapshot to the router's byte-based
    /// ``DownloadProgress``.
    ///
    /// The unit contract is **bytes**: `bytesTotal` is the snapshot's total byte
    /// size and `bytesDownloaded` is the bytes streamed so far, so the surfaced
    /// percentage is byte-accurate for the multi-GB weight downloads a UI bar
    /// tracks. The concrete Hub downloader the integration wiring injects
    /// (`#hubDownloader()`, forwarding `HubClient.downloadSnapshot`) builds its
    /// snapshot `Progress` byte-weighted: `totalUnitCount` is the sum of every
    /// entry's byte size, and each file is a child progress whose unit weight is
    /// that file's byte size. So `totalUnitCount` is the real byte total (mapped
    /// straight to ``DownloadProgress/bytesTotal``, no synthetic total).
    ///
    /// The downloaded count, however, is **not** `completedUnitCount`. Foundation
    /// aggregates a parent-with-children `Progress` only through
    /// `fractionCompleted`; its `completedUnitCount` counts only *whole completed
    /// children* — a shard streaming through reads `0` until it finishes and then
    /// jumps by its full size. For a multi-GB single-shard model that is a single
    /// `0 → 100` leap, not a live percentage. The honest incremental byte count is
    /// therefore `fractionCompleted × totalUnitCount`, rounded — which streams
    /// smoothly and still reaches exactly `bytesTotal` at completion
    /// (`fractionCompleted == 1`).
    ///
    /// Before any total is known the parent reports `0` bytes, which
    /// ``SlotProgress/progressFraction`` treats as an unknown total (fraction `0`)
    /// rather than a divide-by-zero; the ``Router/reporter(slot:progress:)`` this
    /// feeds only adopts a `bytesTotal` once it is reported (`> 0`).
    ///
    /// Kept at the default (module-internal) access level, distinct from
    /// ``handler(reporting:)`` below: this is the pure byte-accounting logic, and
    /// ``LiveModelLoaderTests`` exercises it directly (no network, no GPU) via
    /// `@testable import`. `handler(reporting:)` is just `@Sendable`-closure
    /// plumbing over this function for `loadLLM`'s progress forwarding, used
    /// nowhere else, so it stays `private`.
    ///
    /// - Parameter progress: The Foundation `Progress` snapshot to map.
    /// - Returns: The equivalent byte-based ``DownloadProgress``.
    internal static func mapProgress(_ progress: Progress) -> DownloadProgress {
        let bytesTotal = progress.totalUnitCount
        let bytesDownloaded = Int64((progress.fractionCompleted * Double(bytesTotal)).rounded())
        return DownloadProgress(bytesDownloaded: bytesDownloaded, bytesTotal: bytesTotal)
    }

    /// Adapts the injected Hub downloader's progress to the router's callback.
    ///
    /// Thin `@Sendable`-closure plumbing over ``mapProgress(_:)``, used only by
    /// `loadLLM` above to forward each downloaded-bytes update to its
    /// `reporting` callback. See ``mapProgress(_:)`` for the actual byte-mapping
    /// contract and rationale.
    ///
    /// - Parameter reporting: The router's byte-based progress callback to invoke
    ///   for each Foundation `Progress` update.
    /// - Returns: A `@Sendable` `Progress` observer that maps each update into a
    ///   byte-based ``DownloadProgress`` and forwards it to `reporting`.
    private static func handler(
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) -> @Sendable (Progress) -> Void {
        { progress in
            reporting(Self.mapProgress(progress))
        }
    }
}

/// The default ``ModelLoader`` when none is supplied.
///
/// It cannot load anything and throws ``ModelLoaderError/notConfigured`` on
/// first use. Because the live download path requires an injected `Downloader` /
/// `TokenizerLoader` (see ``LiveModelLoader``), a `Router` built with no loader
/// can size and joint-fit a profile but cannot download or load models — callers
/// that want real loading pass a configured ``LiveModelLoader``, and unit tests
/// pass a stub. This makes that requirement explicit rather than silently
/// loading nothing.
public struct UnconfiguredModelLoader: ModelLoader {
    /// Creates the unconfigured sentinel loader.
    public init() {}

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel cannot load a generation model. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameters:
    ///   - ref: The model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - context: The context length the model would be sized for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
    public func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel cannot load an embedding model. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameters:
    ///   - ref: The embedding model reference that would be loaded.
    ///   - slot: The slot the model would be loaded for.
    ///   - reporting: The download-progress callback (never invoked).
    /// - Returns: Never returns normally — this sentinel always throws.
    /// - Throws: ``ModelLoaderError/notConfigured``, always.
    public func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        throw ModelLoaderError.notConfigured
    }

    /// Always throws ``ModelLoaderError/notConfigured``.
    ///
    /// This sentinel has no container to warm. Real loading is
    /// configured/injected via ``LiveModelLoader`` (milestone 7).
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: Always throws ``ModelLoaderError/notConfigured``.
    public func preload(container: any LoadedModelContainer) async throws {
        throw ModelLoaderError.notConfigured
    }
}
