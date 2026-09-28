import FoundationModelsExtras

/// A reference to one model: a Hugging Face repository, and an optional
/// revision. `FoundationModelsExtras` owns the type. This alias keeps the
/// router name, so a router user needs no `import FoundationModelsExtras`.
public typealias ModelRef = FoundationModelsExtras.ModelRef

/// The work queue of one resident model: one worker runs the submissions of
/// the model one at a time, first in first out (`generation-queue.md`,
/// section 5.3). `FoundationModelsExtras` owns the type. This alias keeps the
/// router name, so a router user needs no `import FoundationModelsExtras`.
///
/// There is one queue for each pool entry. The entry of the model in the
/// Extras model pool makes the queue and owns it
/// (``FoundationModelsExtras/ModelHold/queue``). No router type makes one. The
/// router gives the queue to the container
/// (``LoadedLLMContainer/submitting(to:)``), each backend of that container
/// names it (``LanguageModelSessionBackend/generationQueue``), and the session
/// of that backend submits each of its SDK calls to it as one item. An embed
/// call of a ``RoutedEmbedder`` is one item of the queue of the embedding
/// model.
public typealias GenerationQueue = FoundationModelsExtras.GenerationQueue

/// A refusal of a submission to a ``GenerationQueue`` that could never run
/// (`generation-queue.md`, section 5.5, rule 2). `FoundationModelsExtras`
/// owns the type. This alias keeps the router name, so a router user needs no
/// `import FoundationModelsExtras`.
public typealias GenerationQueueError = FoundationModelsExtras.GenerationQueueError
