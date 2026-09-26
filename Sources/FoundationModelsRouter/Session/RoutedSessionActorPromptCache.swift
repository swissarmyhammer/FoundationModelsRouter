/// ``RoutedSessionActor``'s side of the prompt cache of its model (task
/// ^cc2tezn, `generation-queue.md`, sections 2 and 3).
///
/// The session keys the prompt cache of each of its passes by its own ULID,
/// and releases that key when it closes. The key is the id of the session,
/// not the id of the first transcript entry:
///
/// - A fork is a new session with its own ULID, so a fork and its parent have
///   two keys, and neither takes the cache of the other.
/// - A compaction, a repetition rebuild and discovery priming replace
///   ``backend``, and the session installs the same ULID on the new backend.
///   So the key does not change when the first entry goes, and there is
///   nothing to release on a replacement.
/// - A summarizer backend (the own-model tier and the flash tier of a
///   compaction) is never adopted as ``backend``, so it does not get the key
///   of the session.
/// - All backends of one session run over one raw model, because
///   `replacingTranscript` keeps the model. The release through the current
///   ``backend`` thus reaches each model that the session used.
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
}
