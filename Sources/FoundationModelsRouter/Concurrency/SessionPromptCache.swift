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
///
/// Each outcome other than ``copied`` copies nothing: the first pass of the
/// fork then reads its prompt in full, and the router sends no budget again.
enum PromptCacheCopyOutcome: Sendable, Equatable {
    /// The cache of the source is now also under the key of the target.
    case copied

    /// The model keeps no cache for the source.
    case sourceNotFound

    /// A pass of the source holds its cache now, so the model copied nothing.
    /// The model does not wait for the pass.
    case sourceInUse

    /// The model has a cache of the source, but it copied nothing, for the
    /// reason.
    case refused(PromptCacheCopyRefusal)

    /// The value of this outcome in the fork log
    /// (``RouterTelemetry/LogMetadataKey/forkPromptCacheCopy``). A refusal
    /// gives its reason too, so each outcome has its own value.
    var logValue: String {
        switch self {
        case .copied: "copied"
        case .sourceNotFound: "sourceNotFound"
        case .sourceInUse: "sourceInUse"
        case .refused(let refusal): "refused.\(refusal.rawValue)"
        }
    }
}

/// Why a model did not copy the cache of a source that it has
/// (``PromptCacheCopyOutcome/refused(_:)``).
enum PromptCacheCopyRefusal: String, Sendable, Equatable {
    /// The source and the target are the same session.
    case sameSession

    /// The target has a cache already.
    case destinationHasCache

    /// A pass of the target runs now and holds its cache.
    case destinationInUse

    /// No part of the cache of the source could be copied.
    case copyFailed
}

/// A raw model that keeps a prompt cache for each session, and can copy the
/// cache of one session to the key of another session (D205 (f)). A fork
/// calls it through ``SessionPromptCacheScoping/copyPromptCache(fromSession:toSession:)``.
///
/// The copy and the source are independent: a pass of one does not change
/// the cache of the other, and a release of one key does not release the
/// other key. `MLXLanguageModel` conforms (task ^jx6ng3r). The GGUF cache
/// has no session key, so the GGUF model does not conform, and the router
/// calls no copy for a GGUF slot: on a partial hit of a live record, the cache
/// of FoundationModelsLlamaCpp copies the live sequence itself, and the record
/// of the source stays live (task ^h3xtekz).
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

extension MLXLanguageModel: SessionPromptCacheCopying {
    /// Copies the prompt cache of `sourceSessionID` to the key of
    /// `targetSessionID` with the copy of mlx-swift-lm, and maps its result to
    /// the router outcome.
    ///
    /// The copy of mlx-swift-lm does not wait: when a pass of the source
    /// holds its cache, it gives `.sourceInUse` at once. It has each token of
    /// the source, and the first pass of the target rewinds it to the common
    /// prefix of its own render. It goes into the store of mlx-swift-lm at
    /// once, so `promptCacheUsage` counts it and the memory budget applies to
    /// it.
    ///
    /// - Parameters:
    ///   - sourceSessionID: The session id whose cache the copy reads.
    ///   - targetSessionID: The session id that the copy writes.
    /// - Returns: The outcome of the copy.
    func copyPromptCache(fromSession sourceSessionID: String, toSession targetSessionID: String) async
        -> PromptCacheCopyOutcome
    {
        let result: PromptCacheCopyResult = await copyPromptCache(
            fromSession: sourceSessionID, toSession: targetSessionID)
        return PromptCacheCopyOutcome(result)
    }
}

extension PromptCacheCopyOutcome {
    /// The router outcome of a copy of mlx-swift-lm. The router keeps no
    /// token count of a copy: the first pass of the fork reports the tokens
    /// that it reused.
    ///
    /// - Parameter result: The result of
    ///   `MLXLanguageModel.copyPromptCache(fromSession:toSession:)`.
    init(_ result: PromptCacheCopyResult) {
        switch result {
        case .copied: self = .copied
        case .sourceNotFound: self = .sourceNotFound
        case .sourceInUse: self = .sourceInUse
        case .refused(let refusal): self = .refused(PromptCacheCopyRefusal(refusal))
        }
    }
}

extension PromptCacheCopyRefusal {
    /// The router reason of a refusal of mlx-swift-lm.
    ///
    /// - Parameter refusal: The reason that mlx-swift-lm gave.
    init(_ refusal: PromptCacheCopyResult.Refusal) {
        switch refusal {
        case .sameSession: self = .sameSession
        case .destinationHasCache: self = .destinationHasCache
        case .destinationInUse: self = .destinationInUse
        case .copyFailed: self = .copyFailed
        }
    }
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
