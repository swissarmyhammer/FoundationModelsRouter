import FoundationModelsExtras

/// A reference to one model: a Hugging Face repository, and an optional
/// revision. `FoundationModelsExtras` owns the type. This alias keeps the
/// router name, so a router user needs no `import FoundationModelsExtras`.
public typealias ModelRef = FoundationModelsExtras.ModelRef
