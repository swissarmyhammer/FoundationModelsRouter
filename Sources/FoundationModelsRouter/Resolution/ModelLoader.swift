import Foundation
import FoundationModels

/// A single download-progress observation for one model: the bytes that have
/// arrived out of the total.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes downloaded so far.
    let bytesDownloaded: Int64

    /// Total bytes expected, or `0` when not yet known.
    let bytesTotal: Int64

    /// Creates a download-progress observation.
    init(bytesDownloaded: Int64, bytesTotal: Int64) {
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// The fraction downloaded in `0...1`, or `0` when the total is unknown.
    var fraction: Double {
        bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
    }
}

/// A loaded, resident model handle the router hands to a routed slot. A marker
/// protocol, so the live loader and test stubs can both supply handles.
public protocol LoadedModelContainer: Sendable {}

/// A loaded generation (`standard`/`flash`) model container. Every generation
/// call a ``RoutedSession`` performs runs through a backend this container makes.
public protocol LoadedLLMContainer: LoadedModelContainer {
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

    /// The raw `FoundationModels.LanguageModel` this container wraps. The
    /// default traps. Only a container that supports ``RoutedModel/makeLanguageModel()`` must override it.
    var languageModel: any FoundationModels.LanguageModel { get }
}

extension LoadedLLMContainer {
    /// Traps. See ``LoadedLLMContainer/languageModel``.
    var languageModel: any FoundationModels.LanguageModel {
        preconditionFailure(
            "this LoadedLLMContainer does not expose a languageModel; RoutedModel.makeLanguageModel() is unavailable for it"
        )
    }

    /// Ignores `tools` and forwards to ``makeSession(instructions:)``.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions)
    }

    /// Ignores `tools` and forwards to ``makeSession(transcript:)``.
    func makeSession(transcript: FoundationModels.Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript)
    }
}

/// A loaded embedding model container. ``RoutedEmbedder`` runs its embedding
/// computation through it.
public protocol LoadedEmbeddingContainer: LoadedModelContainer {
    /// The length of every embedding vector this model produces.
    var dimension: Int { get }

    /// Embeds each input string into a ``dimension``-length vector.
    ///
    /// - Returns: One vector per input, in order.
    func embed(texts: [String]) async throws -> [[Float]]
}

/// The download-and-load step behind ``Router/resolve(profile:reporting:)``.
/// The live implementation is ``LiveModelLoader``.
public protocol ModelLoader: Sendable {
    /// Downloads and loads a generation model. Reports download progress to
    /// `reporting`.
    ///
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
    /// from ``LanguageModelProfile/release()``. Non-throwing.
    func evict(container: any LoadedModelContainer) async
}

extension ModelLoader {
    /// A no-op eviction. Only a loader that manages residency overrides it.
    public func evict(container: any LoadedModelContainer) async {}
}
