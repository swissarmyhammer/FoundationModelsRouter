import Foundation

/// A session's key/value attention cache — the prefilled-prefix compute a
/// session accumulates and a fork inherits by copy.
///
/// A ``RoutedSession`` owns exactly one cache for its lifetime, and the cache
/// **dies with the session** (ARC): releasing a session frees its KV memory.
/// ``copy()`` is the fork seam — a ``RoutedSession/fork(workingDirectory:)``
/// begins the child with a copy of the parent's cache, so the child inherits the
/// prefix compute and then diverges independently rather than replaying the
/// conversation.
///
/// The concept is abstracted behind this protocol (rather than the MLX cache
/// directly) so the fork/copy/free contract is unit-testable without a GPU: the
/// suite substitutes a stub that records `copy()` invocations and its free on
/// release. The live ``LoadedLLMContainer`` (an MLX `ModelContainer`) backs this
/// with the real `KVCache.copy()`; real prefix reuse (no recompute) lands in the
/// gated milestone 7 integration suite.
///
/// It is class-bound and `Sendable` so a session (an actor) can hold one across
/// isolation boundaries and free it deterministically by dropping its reference.
public protocol SessionKVCache: AnyObject, Sendable {
    /// Returns an independent copy of this cache — the fork seam.
    ///
    /// The returned cache begins equal to this one (the parent's prefilled
    /// prefix) and then diverges: mutations to either do not affect the other.
    /// Backed by MLX `KVCache.copy()` in the live container.
    ///
    /// - Returns: A new cache that starts as a copy of this one.
    func copy() -> any SessionKVCache
}

extension LoadedLLMContainer {
    /// The default KV cache for a new session over this model: an inert cache
    /// that holds nothing and frees nothing.
    ///
    /// The live `ModelContainer` (milestone 7) overrides this to allocate a real
    /// MLX cache; every other conformer — including the deferred live container
    /// until its generation pipeline is wired — inherits this inert default so a
    /// vended session always has a well-defined cache to own, copy on fork, and
    /// free on release, with no GPU dependency.
    ///
    /// - Returns: A fresh inert ``SessionKVCache``.
    public func makeCache() -> any SessionKVCache {
        InertKVCache()
    }
}

/// The inert ``SessionKVCache`` a container gets by default until it wires a real
/// one: it holds no KV state, so ``copy()`` just yields another inert cache and
/// its release frees nothing. It exists so the fork/copy/free surface is
/// well-defined for every container without a GPU-backed cache.
final class InertKVCache: SessionKVCache {
    /// Returns another inert cache — there is no prefix state to carry.
    func copy() -> any SessionKVCache {
        InertKVCache()
    }
}
