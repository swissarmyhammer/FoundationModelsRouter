import Foundation
import FoundationModelsExtras
import os

/// The logger of the router loader in the Extras model pool.
private let slotPoolLoaderLogger = makeModuleLogger(category: "ModelPool")

/// The loader that the router gives to the Extras model pool for one slot.
///
/// The Extras loader protocol loads by ``ModelPoolKey`` only: a ref and a
/// role. The router loader needs more: the slot, the advisory working context
/// and the progress callback of the resolve. The router gives that slot data
/// when it makes this loader, not through the pool. The ``evict(_:)`` step of
/// the pool comes back through the Extras protocol to
/// ``ModelLoader/evict(container:)``.
///
/// The first loader of a key wins: a later caller of the same key gets the
/// container of the first loader, whatever loader it gives. Thus a caller
/// uses an embedding hold through ``PooledEmbedder`` (the Extras embed
/// protocol) and a generation hold through
/// ``FoundationModelsExtras/ModelHold/generationContainer()``, never by a
/// cast to ``LoadedEmbeddingContainer``.
struct SlotPoolLoader: PooledModelLoader {
    /// The router loader that downloads and loads the model.
    let loader: any ModelLoader

    /// The slot that the model is loaded for.
    let slot: ModelSlot

    /// The working context of the first resolve. Advisory only; see
    /// ``ModelLoader/loadLLM(ref:slot:context:reporting:)``.
    let context: Int

    /// Receives each download-progress value of the load.
    let reporting: @Sendable (DownloadProgress) -> Void

    /// Loads the model of `key` through the router loader, with the slot data
    /// of this loader. The role of `key` selects the generation load or the
    /// embedding load.
    ///
    /// - Parameter key: The model and its role.
    /// - Returns: The loaded container.
    /// - Throws: What the router loader throws.
    func load(_ key: ModelPoolKey) async throws -> any Sendable {
        switch key.role {
        case .llm:
            try await loader.loadLLM(ref: key.ref, slot: slot, context: context, reporting: reporting)
        case .embedding:
            try await loader.loadEmbedder(ref: key.ref, slot: slot, reporting: reporting)
        }
    }

    /// Evicts a container that ``load(_:)`` returned, through
    /// ``ModelLoader/evict(container:)``. The pool gives back only the
    /// containers of this loader, so each one is a ``LoadedModelContainer``.
    ///
    /// - Parameter container: The container to evict.
    func evict(_ container: any Sendable) async {
        guard let loaded = container as? any LoadedModelContainer else {
            let containerType = String(describing: type(of: container))
            assertionFailure("the pool gave back a \(containerType), which the router loader did not load")
            slotPoolLoaderLogger.error(
                "the pool gave back a \(containerType, privacy: .public), which the router loader did not load; the eviction does nothing"
            )
            return
        }
        await loader.evict(container: loaded)
    }

    /// Gives a hold of `ref` in the role of ``slot``, inside a running
    /// admission job. A resident key adds a hold at once; a new key loads
    /// through this loader at once, with no second wait in the admission
    /// queue, so the job cannot wait for itself.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - admission: The Extras model pool inside the running admission job.
    ///   - footprintBytes: The weights and one session.
    ///   - sessionBytes: The session of this hold.
    /// - Returns: The hold. Its container can come from a loader that is not
    ///   the router's.
    /// - Throws: What the load throws.
    func acquireHold(
        of ref: ModelRef, in admission: ModelPoolAdmission, footprintBytes: Int64, sessionBytes: Int64
    ) async throws -> ModelHold {
        try await admission.acquire(
            ModelPoolKey(ref: ref, role: slot.poolRole), footprintBytes: footprintBytes,
            sessionBytes: sessionBytes, loader: self)
    }
}

extension ModelHold {
    /// The container of this hold as a generation container whose backends
    /// name ``queue``, the one work queue of the pool entry. Thus each session
    /// of each holder of the key submits to that queue.
    ///
    /// - Returns: The container, cast to ``LoadedLLMContainer`` and given
    ///   ``queue`` through ``LoadedLLMContainer/submitting(to:)``.
    /// - Throws: ``PooledGenerationError/notAGenerationContainer(key:containerType:)``
    ///   when the first loader of the key gave a container that is not a
    ///   ``LoadedLLMContainer``.
    func generationContainer() throws -> any LoadedLLMContainer {
        guard let generation = container as? any LoadedLLMContainer else {
            throw PooledGenerationError.notAGenerationContainer(
                key: key, containerType: String(describing: type(of: container)))
        }
        return generation.submitting(to: queue)
    }
}

/// An error of a generation hold in the Extras model pool.
enum PooledGenerationError: Error, Equatable, LocalizedError {
    /// The container of `key` has the type `containerType`, which does not
    /// conform to ``LoadedLLMContainer``.
    case notAGenerationContainer(key: ModelPoolKey, containerType: String)

    /// A message that tells what is wrong.
    var errorDescription: String? {
        switch self {
        case .notAGenerationContainer(let key, let containerType):
            """
            The container of \(key.ref.stringValue) is a \(containerType), which does not conform to \
            LoadedLLMContainer. The first loader of a key gives the container of all holds, so each \
            loader of a generation key that the router uses must return a LoadedLLMContainer.
            """
        }
    }
}
