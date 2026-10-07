import Foundation
import FoundationModels

/// A single download-progress observation for one model: the bytes that have
/// arrived out of the total.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes downloaded so far.
    public let bytesDownloaded: Int64

    /// Total bytes expected, or `0` when not yet known.
    public let bytesTotal: Int64

    /// Creates a download-progress observation.
    public init(bytesDownloaded: Int64, bytesTotal: Int64) {
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// The fraction downloaded in `0...1`, or `0` when the total is unknown.
    public var fraction: Double {
        bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
    }
}

/// A loaded, resident model handle the router hands to a routed slot. A marker
/// protocol, so the live loader and test stubs can both supply handles.
public protocol LoadedModelContainer: Sendable {}

/// A loaded generation (`standard`/`flash`) model container. Every generation
/// call a ``RoutedSession`` performs runs through a backend this container makes.
///
/// The entry of the model in the Extras model pool owns the one
/// ``GenerationQueue`` of the model (``FoundationModelsExtras/ModelHold/queue``).
/// The router gives that queue to the container through
/// ``submitting(to:)``, and each backend of the copy that it gets back names
/// the queue (``LanguageModelSessionBackend/generationQueue``). Thus the
/// session of the backend submits each whole SDK call to it
/// (`generation-queue.md`, section 5.3), and all users of one model share one
/// queue. A container that keeps the default ``submitting(to:)`` and whose
/// backends name no queue (a test stub or a third-party container) gets no
/// generation gating from the Router: two sessions over it can generate at
/// the same time.
public protocol LoadedLLMContainer: LoadedModelContainer {
    /// Gives a copy of this container whose backends name `queue`, the work
    /// queue of the pool entry of the model. The router calls it once for
    /// each hold, before it makes a session backend.
    ///
    /// The default gives this container: its backends keep the queue that
    /// they name, or no queue.
    ///
    /// - Parameter queue: The work queue of the pool entry of the model.
    /// - Returns: The container whose backends name `queue`.
    func submitting(to queue: GenerationQueue) -> any LoadedLLMContainer

    /// Makes a new session backend over this resident model.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend

    /// Makes a new session backend over this resident model with `tools`. The
    /// default ignores `tools` and forwards to ``makeSession(instructions:)``.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend

    /// Makes a new session backend seeded from `transcript`.
    func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend

    /// Makes a new session backend seeded from `transcript` with `tools`. The
    /// default ignores `tools` and forwards to ``makeSession(transcript:)``.
    func makeSession(transcript: FoundationModels.Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend

    /// Makes a new session backend over this resident model that decodes
    /// with `samplingMode`. The default drops `samplingMode` and forwards to
    /// ``makeSession(instructions:)``.
    ///
    /// The mode is the router's, not the container's: two routers over one
    /// pooled container each pass their own mode.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`
    ///     for the container's default.
    func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend

    /// Makes a new session backend over this resident model with `tools`
    /// that decodes with `samplingMode`. The default drops `samplingMode` and
    /// forwards to ``makeSession(instructions:tools:)``.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools the model can call.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`
    ///     for the container's default.
    func makeSession(
        instructions: String?, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend

    /// Makes a new session backend seeded from `transcript` that decodes
    /// with `samplingMode`. The default drops `samplingMode` and forwards to
    /// ``makeSession(transcript:)``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the backend from.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`
    ///     for the container's default.
    func makeSession(
        transcript: FoundationModels.Transcript, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend

    /// Makes a new session backend seeded from `transcript` with `tools`
    /// that decodes with `samplingMode`. The default drops `samplingMode` and
    /// forwards to ``makeSession(transcript:tools:)``.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the backend from.
    ///   - tools: The tools the model can call.
    ///   - samplingMode: The decoding strategy the router asked for, or `nil`
    ///     for the container's default.
    func makeSession(
        transcript: FoundationModels.Transcript, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend

    /// The counter that counts tokens the way this container's model counts
    /// them. A session vended over this container owns it, and counts every
    /// transcript, summary and tool output with it before a model call. The
    /// live container backs it with the loaded tokenizer; a scripted
    /// container supplies its own rule.
    var tokenCounter: any TokenCounter { get }
}

extension LoadedLLMContainer {
    /// Gives this container unchanged: its backends keep the queue that they
    /// name, or no queue.
    public func submitting(to queue: GenerationQueue) -> any LoadedLLMContainer {
        self
    }

    /// Ignores `tools` and forwards to ``makeSession(instructions:)``.
    public func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions)
    }

    /// Ignores `tools` and forwards to ``makeSession(transcript:)``.
    public func makeSession(
        transcript: FoundationModels.Transcript, tools: [any Tool]
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript)
    }

    /// Drops `samplingMode` and forwards to ``makeSession(instructions:)``.
    public func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions)
    }

    /// Drops `samplingMode` and forwards to ``makeSession(instructions:tools:)``.
    public func makeSession(
        instructions: String?, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: tools)
    }

    /// Drops `samplingMode` and forwards to ``makeSession(transcript:)``.
    public func makeSession(
        transcript: FoundationModels.Transcript, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript)
    }

    /// Drops `samplingMode` and forwards to ``makeSession(transcript:tools:)``.
    public func makeSession(
        transcript: FoundationModels.Transcript, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: tools)
    }
}

/// A loaded embedding model container. ``RoutedEmbedder`` runs its embedding
/// computation through it.
///
/// The requirement comes from the Extras embed protocol, ``PooledEmbedding``:
/// `embed(texts:)`, one vector for each text, in order. The protocol gives no
/// vector length; read it from the `count` of a vector. The first loader of a key gives the container of
/// all holds of that key, so a container in the Extras pool can be a
/// ``PooledEmbedding`` from a loader that is not the router's. Thus router
/// code uses a pooled embedding container through ``PooledEmbedding`` and
/// never casts it to this protocol.
public protocol LoadedEmbeddingContainer: LoadedModelContainer, PooledEmbedding {}

/// The download-and-load step behind ``Router/resolve(profile:reporting:)``.
/// The live implementation is ``LiveModelLoader``.
public protocol ModelLoader: Sendable {
    /// Downloads and loads a generation model. Reports download progress to
    /// `reporting`.
    ///
    /// The container is keyed in the pool by `ref` and its role only, and one
    /// container serves every working context. `context` is advisory: a
    /// loader must not size the container or its KV cache by it. The KV
    /// cache is allocated per session and priced per session by the router.
    ///
    /// - Parameters:
    ///   - ref: The model to download and load.
    ///   - slot: The slot the model is loaded for.
    ///   - context: The working context the first resolve decodes at. Advisory only.
    ///   - reporting: Receives each download-progress observation.
    /// - Throws: If the download or load fails.
    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer

    /// Downloads and loads an embedding model. Reports download progress to
    /// `reporting`.
    ///
    /// - Throws: If the download or load fails.
    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer

    /// Warms a freshly loaded container.
    ///
    /// - Throws: If warm-up fails.
    func preload(container: any LoadedModelContainer) async throws

    /// Evicts a resident container and releases the memory it holds. Called
    /// when the last reference to a residency goes away. Non-throwing.
    func evict(container: any LoadedModelContainer) async

    /// Sets the memory budget of the prompt cache that the models of this
    /// loader keep. The pool calls it each time its resident footprint
    /// changes, with the working set less the resident footprints and less
    /// the prompt-cache bytes that are being written to disk
    /// (`generation-queue.md`, section 3).
    ///
    /// - Parameter memoryBudgetBytes: The most bytes the prompt-cache entries
    ///   in memory may hold.
    func configurePromptCache(memoryBudgetBytes: Int) async

    /// The bytes the prompt cache of the models of this loader holds now.
    var promptCacheUsage: PromptCacheUsage { get async }
}

extension ModelLoader {
    /// A no-op eviction. Only a loader that manages residency overrides it.
    public func evict(container: any LoadedModelContainer) async {}

    /// A no-op budget. Only a loader whose models keep a prompt cache
    /// overrides it. When a loader does not, its runtime keeps its own default.
    public func configurePromptCache(memoryBudgetBytes: Int) async {}

    /// No usage. Only a loader whose models keep a prompt cache overrides it.
    public var promptCacheUsage: PromptCacheUsage {
        get async { .zero }
    }
}
