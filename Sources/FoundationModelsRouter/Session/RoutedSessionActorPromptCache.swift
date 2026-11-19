/// ``RoutedSessionActor``'s side of the prompt cache of its model (task
/// ^cc2tezn).
///
/// The session keys the prompt cache of each of its passes by its own ULID,
/// and releases that key when it closes. The key is the id of the session,
/// not the id of the first transcript entry:
///
/// - Each session has its own ULID, so two sessions have two keys, and
///   neither takes the cache of the other.
/// - A compaction, a repetition rebuild and discovery priming replace
///   ``backend``, and the session installs the same ULID on the new backend.
///   So the key does not change when the first entry goes, and there is
///   nothing to release on a replacement.
/// - A summarizer backend (the own-model tier and the flash tier of a
///   compaction) is never adopted as ``backend``, so it does not get the key
///   of the session. Its passes bind the `.uncached` scope (task ^ptev9yy),
///   so a compaction adds no key to the cache of the model.
/// - All backends of one session run over one raw model, because
///   `replacingTranscript` keeps the model. The release through the current
///   ``backend`` thus reaches each model that the session used.
/// - A fork has its own ULID, so its own key. Its cache starts as a copy of
///   the cache of its source (D205 (f), ``takePromptCacheCopy(of:through:)``),
///   and the close of each session releases only its own key.
extension RoutedSessionActor {
    /// The id that keys the prompt cache of the passes of this session: the
    /// string form of ``id``.
    nonisolated var promptCacheSessionID: String { id.description }

    /// Makes `backend` a backend of this session: its passes report to this
    /// session's pass observer, and key the prompt cache by
    /// ``promptCacheSessionID``. The initializer and each replacement of
    /// ``backend`` call it.
    ///
    /// - Parameter backend: The backend this session runs through from now on.
    nonisolated func adopt(_ backend: any LanguageModelSessionBackend) {
        observeGenerationPasses(of: backend)
        (backend as? any SessionPromptCacheScoping)?.scopePromptCache(toSession: promptCacheSessionID)
    }

    /// Releases the prompt cache of this session on the model of ``backend``.
    /// ``close()`` calls it. A second close calls it again, and the release of
    /// a key that the model does not know is a no-op.
    func releasePromptCache() async {
        await (backend as? any SessionPromptCacheScoping)?.releasePromptCache(ofSession: promptCacheSessionID)
    }

    /// Starts the prompt cache of this fork as a copy of the prompt cache of
    /// `source` (D205 (f)): the model copies the cache of
    /// ``promptCacheSessionID`` of `source` to the key of this fork.
    /// ``makeFork(id:seed:surface:)`` of `source` calls it before it returns,
    /// so the copy ends before the directory mails the first prompt of the
    /// fork.
    ///
    /// The copy holds the whole cache of `source`. The first pass of the
    /// fork renders the history up to the cut, and the reuse rules of the
    /// model rewind the copy to the common prefix. The Router counts no
    /// tokens. After the copy the two keys are independent: a close of this
    /// fork releases only its own key (``releasePromptCache()``), and a close
    /// of `source` releases only the key of `source`.
    ///
    /// The copy runs only when this fork and `source` run on the same slot
    /// and the same model reference: the cache of a different model is of
    /// no use to this fork.
    ///
    /// The outcome goes to the log with the id of this fork. After a copy,
    /// `handle` sends the prompt-cache budget again, so the next budget
    /// counts the copy.
    ///
    /// - Parameters:
    ///   - source: The session that this fork comes from.
    ///   - handle: The handle that made this fork.
    func takePromptCacheCopy(of source: RoutedSessionActor, through handle: RoutedLLM) async {
        guard slot == source.slot, model == source.model,
            let outcome = await (backend as? any SessionPromptCacheScoping)?.copyPromptCache(
                fromSession: source.promptCacheSessionID, toSession: promptCacheSessionID)
        else { return }
        logPromptCacheCopy(outcome, from: source)
        guard outcome == .copied else { return }
        await handle.promptCacheBudgetSender?()
    }

    /// Logs the outcome of the copy of the prompt cache of `source` to this
    /// fork, with the ids of `source` and of this fork, as the fork log of
    /// ``RouterSessionDirectory/fork(_:)`` names them.
    ///
    /// - Parameters:
    ///   - outcome: The outcome of the copy.
    ///   - source: The session that this fork comes from.
    private func logPromptCacheCopy(_ outcome: PromptCacheCopyOutcome, from source: RoutedSessionActor) {
        sessionLogger(.sessionDirectory).info(
            "a fork asked for a copy of the prompt cache of its source",
            metadata: [
                RouterTelemetry.LogMetadataKey.sessionId: "\(source.id.description)",
                RouterTelemetry.LogMetadataKey.forkSessionId: "\(id.description)",
                RouterTelemetry.LogMetadataKey.forkPromptCacheCopy: "\(outcome.rawValue)",
            ])
    }
}
