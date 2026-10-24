import FoundationModelsExtras

/// A reference to one model: a Hugging Face repository, and an optional
/// revision. `FoundationModelsExtras` owns the type. This alias keeps the
/// router name, so a router user needs no `import FoundationModelsExtras`.
public typealias ModelRef = FoundationModelsExtras.ModelRef

/// A refusal of a wait that could never end: an in-band tool body that waits
/// for an answer of its own session. `FoundationModelsExtras` owns the type.
/// This alias keeps the router name, so a router user needs no `import
/// FoundationModelsExtras`.
public typealias GenerationQueueError = FoundationModelsExtras.GenerationQueueError
