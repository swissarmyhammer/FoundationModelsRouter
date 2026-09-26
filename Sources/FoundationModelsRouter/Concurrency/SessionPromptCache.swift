import MLXFoundationModels

/// A raw model that keeps a prompt cache for each session, and can release
/// the cache of one session (`generation-queue.md`, section 3).
///
/// `MLXLanguageModel` conforms: its `releasePromptCache(sessionID:)` removes
/// the entry of the session from memory, from the spill queue and from disk.
protocol SessionPromptCacheReleasing: Sendable {
    /// Releases the prompt cache that the passes of session `sessionID` keep
    /// on this model. A session that this model does not know is a no-op.
    ///
    /// - Parameter sessionID: The id that the passes of the session bound as
    ///   their `.session` prompt-cache scope.
    func releasePromptCache(sessionID: String) async
}

extension MLXLanguageModel: SessionPromptCacheReleasing {}

/// A session backend whose passes key the prompt cache of its model by the
/// id of the session that owns the backend (`generation-queue.md`,
/// section 3).
///
/// ``MLXFoundationModelsSessionBackend`` conforms: it runs its
/// `LanguageModelSession` over a per-session ``SessionLanguageModel``, whose
/// executor binds the scope on the task of each pass. A backend with no
/// executor seam does not conform, and its session keys no cache.
protocol SessionPromptCacheScoping: AnyObject, Sendable {
    /// Keys the prompt cache of each later pass of this backend by
    /// `sessionID`.
    ///
    /// - Parameter sessionID: The id of the session that owns this backend.
    func scopePromptCache(toSession sessionID: String)

    /// Releases the prompt cache of `sessionID` on the model of this backend.
    ///
    /// - Parameter sessionID: The id that the passes of the session bound.
    func releasePromptCache(ofSession sessionID: String) async
}
