@testable import FoundationModelsRouter

extension RoutedModel where Container == any LoadedLLMContainer {
    /// The work queue that each session backend of this handle names: the
    /// queue of the pool entry of the model after a resolve, or `nil` when
    /// the container names no queue. The value comes from a new backend of the
    /// container, so it is the queue that a new session of this handle submits
    /// to.
    var backendQueue: GenerationQueue? {
        container.makeSession(instructions: nil).generationQueue
    }
}
