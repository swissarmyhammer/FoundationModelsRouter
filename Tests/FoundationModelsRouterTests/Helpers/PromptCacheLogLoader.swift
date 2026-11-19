import Synchronization

@testable import FoundationModelsRouter

/// A ``ModelLoader`` that records each prompt-cache memory budget it gets,
/// and reports the prompt-cache usage of a ``PromptCacheScopeLog``.
///
/// It gives each load to a ``StubModelLoader`` over one container, so each
/// generation slot runs over that container. Thus a copy that the model of
/// the container records changes the usage that the next budget reads.
final class PromptCacheLogLoader: ModelLoader, Sendable {
    /// The log whose usage the loader reports.
    let log: PromptCacheScopeLog

    /// The loader that does each load.
    private let stub: StubModelLoader

    /// Each budget the router sent, in order.
    private let budgets = Mutex<[Int]>([])

    /// Makes a loader over `container` that reports the usage of `log`.
    ///
    /// - Parameters:
    ///   - container: The container that each generation slot loads.
    ///   - log: The log whose usage the loader reports.
    init(container: any LoadedLLMContainer, log: PromptCacheScopeLog) {
        self.log = log
        self.stub = StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
    }

    /// Each memory budget the router sent, in order.
    var memoryBudgets: [Int] { budgets.withLock { $0 } }

    func loadLLM(
        ref: ModelRef,
        slot: ModelSlot,
        context: Int,
        kvCache: KVCacheQuantization?,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedLLMContainer {
        try await stub.loadLLM(ref: ref, slot: slot, context: context, kvCache: kvCache, reporting: reporting)
    }

    func loadEmbedder(
        ref: ModelRef,
        slot: ModelSlot,
        reporting: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> any LoadedEmbeddingContainer {
        try await stub.loadEmbedder(ref: ref, slot: slot, reporting: reporting)
    }

    func preload(container: any LoadedModelContainer) async throws {
        try await stub.preload(container: container)
    }

    /// Records the budget.
    ///
    /// - Parameter memoryBudgetBytes: The budget the router sent.
    func configurePromptCache(memoryBudgetBytes: Int) async {
        budgets.withLock { $0.append(memoryBudgetBytes) }
    }

    /// The usage of ``log``.
    var promptCacheUsage: PromptCacheUsage { log.promptCacheUsage }
}
