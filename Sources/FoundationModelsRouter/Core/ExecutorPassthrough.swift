import FoundationModels

/// Builds the executor of a wrapped `LanguageModel` one time, for a wrapper
/// model whose own executor calls it directly.
///
/// A wrapper (``RecordingLanguageModel``, ``QueuedLanguageModel``) does its
/// own work around one executor call and passes the request through, over the
/// same outer channel, so the wrapped executor sees the request unchanged.
/// ``RecordingLanguageModel`` calls the wrapped executor on the same task, so a
/// task-local value it binds reaches that executor. ``QueuedLanguageModel``
/// calls it on the task that the worker of its ``GenerationQueue`` makes, so
/// only a task-local that the item itself binds reaches that executor.
enum ExecutorPassthrough {
    /// One call of a wrapped executor.
    typealias Respond = @Sendable (
        LanguageModelExecutorGenerationRequest, LanguageModelExecutorGenerationChannel
    ) async throws -> Void

    /// Builds the executor of `wrapped` one time and returns a closure that
    /// calls it over the outer channel unmodified.
    ///
    /// - Parameter wrapped: The raw model to wrap, type-erased.
    /// - Returns: A closure that calls the executor of `wrapped`.
    /// - Throws: What `Wrapped.Executor.init(configuration:)` throws.
    static func make(wrapping wrapped: any LanguageModel) throws -> Respond {
        try makeGeneric(wrapping: wrapped)
    }

    /// Opens the existential of `wrapped` so `Wrapped.Executor` can be built
    /// one time, then closes over that executor and model.
    ///
    /// - Parameter wrapped: The raw model to wrap.
    /// - Returns: A closure that calls the executor of `wrapped`.
    /// - Throws: What `Wrapped.Executor.init(configuration:)` throws.
    private static func makeGeneric<Wrapped: LanguageModel>(wrapping wrapped: Wrapped) throws -> Respond {
        let executor = try Wrapped.Executor(configuration: wrapped.executorConfiguration)
        return { request, channel in
            try await executor.respond(to: request, model: wrapped, streamingInto: channel)
        }
    }
}
