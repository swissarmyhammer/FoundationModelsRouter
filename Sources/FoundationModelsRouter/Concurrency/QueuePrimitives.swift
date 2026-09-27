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
/// There is one queue for each pool entry. The live container
/// (``MLXFoundationModelsContainer``) makes the queue and owns it. Each
/// backend the container makes names this queue
/// (``LanguageModelSessionBackend/generationQueue``), and the session of that
/// backend submits each of its SDK calls to it as one item.
public typealias GenerationQueue = FoundationModelsExtras.GenerationQueue

/// A refusal of a submission to a ``GenerationQueue`` that could never run
/// (`generation-queue.md`, section 5.5, rule 2). `FoundationModelsExtras`
/// owns the type. This alias keeps the router name, so a router user needs no
/// `import FoundationModelsExtras`.
public typealias GenerationQueueError = FoundationModelsExtras.GenerationQueueError
