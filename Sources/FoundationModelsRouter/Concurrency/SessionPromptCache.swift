import MLXFoundationModels

/// A raw model that keeps a prompt cache for each session, and can release
/// the cache of one session.
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

/// The outcome of a copy of the prompt cache of one session to the key of
/// another session (D205 (f)).
enum PromptCacheCopyOutcome: String, Sendable, Equatable {
    /// The cache of the source is now also under the key of the target.
    case copied

    /// The model keeps no cache for the source.
    case sourceNotFound

    /// A pass of the source holds its cache now, so the model copied nothing.
    case sourceInUse
}

/// A raw model that keeps a prompt cache for each session, and can copy the
/// cache of one session to the key of another session (D205 (f)). A fork
/// calls it through ``SessionPromptCacheScoping/copyPromptCache(fromSession:toSession:)``.
///
/// The copy and the source are independent: a pass of one does not change
/// the cache of the other, and a release of one key does not release the
/// other key. No model of the router conforms yet: `MLXLanguageModel` gets
/// the copy in a later mlx-swift-lm release (task ^jx6ng3r). The GGUF cache
/// has no session key, so the GGUF model does not conform.
protocol SessionPromptCacheCopying: Sendable {
    /// Copies the prompt cache of session `sourceSessionID` to the key of
    /// session `targetSessionID`.
    ///
    /// - Parameters:
    ///   - sourceSessionID: The session id whose cache the copy reads.
    ///   - targetSessionID: The session id that the copy writes.
    /// - Returns: The outcome of the copy.
    func copyPromptCache(fromSession sourceSessionID: String, toSession targetSessionID: String) async
        -> PromptCacheCopyOutcome
}

/// A session backend whose passes key the prompt cache of its model by the
/// id of the session that owns the backend.
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

    /// Makes each later pass of this backend keep no prompt cache: it binds
    /// the `.uncached` scope, so it takes no cache and leaves none. A
    /// compaction calls it on the backend of each summarizer call (task
    /// ^ptev9yy), so that call adds no key to the cache of the model.
    func keepNoPromptCache()

    /// Releases the prompt cache of `sessionID` on the model of this backend.
    ///
    /// - Parameter sessionID: The id that the passes of the session bound.
    func releasePromptCache(ofSession sessionID: String) async

    /// Copies the prompt cache of `sourceSessionID` to the key of
    /// `targetSessionID` on the model of this backend.
    ///
    /// - Parameters:
    ///   - sourceSessionID: The session id whose cache the copy reads.
    ///   - targetSessionID: The session id that the copy writes.
    /// - Returns: The outcome of the copy, or `nil` when the model copies
    ///   no cache.
    func copyPromptCache(fromSession sourceSessionID: String, toSession targetSessionID: String) async
        -> PromptCacheCopyOutcome?
}
