import FoundationModelsExtras

/// What a pooled model does: generation (`llm`) or embedding. The Extras
/// model pool keys each model by its ``ModelRef`` and this role.
/// `FoundationModelsExtras` owns the type. This alias keeps a router name, so
/// a router user needs no `import FoundationModelsExtras`. See
/// ``ModelSlot/poolRole`` for the role of each slot.
public typealias ModelRole = FoundationModelsExtras.ModelRole

/// The key of one model in the Extras model pool: a ``ModelRef`` and a
/// ``ModelRole``. `FoundationModelsExtras` owns the type. This alias keeps a
/// router name, so a router user needs no `import FoundationModelsExtras`.
public typealias ModelPoolKey = FoundationModelsExtras.ModelPoolKey

/// The loader protocol of the Extras model pool: it loads a model by its
/// ``ModelPoolKey`` only, and evicts a container that it loaded.
/// ``LiveModelLoader`` conforms to it, so an application can give a live
/// loader to the Extras pool without a ``Router``. `FoundationModelsExtras`
/// owns the protocol. This alias keeps a router name, so a router user needs
/// no `import FoundationModelsExtras`.
public typealias PooledModelLoader = FoundationModelsExtras.PooledModelLoader

/// The embed protocol of the Extras model pool: a vector length and one
/// vector for each text. ``LoadedEmbeddingContainer`` refines it. The first
/// loader of a key gives the container of all holds of that key, so the
/// router uses an embedding container through this protocol only.
/// `FoundationModelsExtras` owns the protocol. This alias keeps a router name,
/// so a router user needs no `import FoundationModelsExtras`.
public typealias PooledEmbedding = FoundationModelsExtras.PooledEmbedding
