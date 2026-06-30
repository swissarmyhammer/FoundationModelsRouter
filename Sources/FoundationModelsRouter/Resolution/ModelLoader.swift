import Foundation

/// A single download-progress observation for one model: how many bytes have
/// arrived out of how many total.
///
/// The loader reports these as a repo's weights stream in so the router can
/// surface a live byte count and an overall ``ResolutionProgress/fraction``.
/// When the total is unknown (`0`), ``fraction`` is `0` rather than undefined.
public struct DownloadProgress: Sendable, Equatable {
    /// Bytes downloaded so far.
    public let bytesDownloaded: Int64

    /// Total bytes expected, or `0` when not yet known.
    public let bytesTotal: Int64

    /// Creates a download-progress observation.
    ///
    /// - Parameters:
    ///   - bytesDownloaded: Bytes downloaded so far.
    ///   - bytesTotal: Total bytes expected, or `0` when unknown.
    public init(bytesDownloaded: Int64, bytesTotal: Int64) {
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
    }

    /// The fraction downloaded in `0...1`, or `0` when the total is unknown.
    public var fraction: Double {
        bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
    }
}

/// A loaded, resident model handle the router hands to a routed slot.
///
/// This is a marker so the concrete container types from the MLX stack
/// (`ModelContainer`, `EmbedderModelContainer`) can be returned by the live
/// loader while tests substitute their own stub handles — neither the router's
/// orchestration nor its unit tests depend on the MLX containers directly. The
/// generation/embedding methods that consume the underlying container land in
/// later milestones (5a/5b).
public protocol LoadedModelContainer: Sendable {}

/// A loaded generation (`standard`/`flash`) model container.
public protocol LoadedLLMContainer: LoadedModelContainer {}

/// A loaded embedding model container.
public protocol LoadedEmbeddingContainer: LoadedModelContainer {}

/// The download-and-load step behind ``Router/resolve(_:reporting:)``,
/// abstracted so the orchestration is unit-testable without network or GPU.
///
/// The live implementation is ``LiveModelLoader``, which downloads weights from
/// the Hugging Face Hub and materializes MLX containers; tests inject a stub
/// that returns fake handles. `loadLLM` and `loadEmbedder` perform the download
/// (reporting byte progress) and produce a resident container; ``preload(_:)``
/// is the warm-up hook run once a container exists.
public protocol ModelLoader: Sendable {
    /// Downloads and loads a generation model, reporting download progress.
    ///
    /// - Parameters:
    ///   - ref: The chosen model reference.
    ///   - slot: The slot the model is being loaded for (`.standard`/`.flash`).
    ///   - context: The working context size in tokens.
    ///   - reporting: A best-effort callback invoked with download progress.
    /// - Returns: A resident generation container.
    /// - Throws: If the download or load fails.
    func loadLLM(
        _ ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer

    /// Downloads and loads an embedding model, reporting download progress.
    ///
    /// - Parameters:
    ///   - ref: The chosen model reference.
    ///   - slot: The slot the model is being loaded for (`.embedding`).
    ///   - reporting: A best-effort callback invoked with download progress.
    /// - Returns: A resident embedding container.
    /// - Throws: If the download or load fails.
    func loadEmbedder(
        _ ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer

    /// Warms a freshly loaded container so the first generation/embedding does
    /// not pay the materialization cost.
    ///
    /// - Parameter container: The container to warm.
    /// - Throws: If warm-up fails.
    func preload(_ container: any LoadedModelContainer) async throws
}
