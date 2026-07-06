import Foundation

/// A session's fork/copy/free lifecycle contract.
///
/// A ``RoutedSession`` owns exactly one cache for its lifetime, and the cache
/// **dies with the session** (ARC): releasing a session frees whatever it holds.
/// ``copy()`` is the fork seam — a ``RoutedSession/fork(workingDirectory:)``
/// begins the child with a copy of the parent's cache.
///
/// **Historical note — not currently backed by real MLX KV state.** This
/// protocol predates the `LanguageModelSession` pivot (see plan.md's "Backends"
/// and "Sessions & KV cache" sections), when it was designed to wrap MLX's own
/// `KVCache` and back `fork()`'s "inherits the parent's prefilled-prefix
/// compute" performance goal via a real `KVCache.copy()`. Under the real
/// `LanguageModelSession`-backed generation path (``MLXFoundationModelsContainer``),
/// a fresh `LanguageModelSession` is constructed **per call** rather than held
/// across calls on this seam, so there is no live per-session engine object
/// here for a live conformance to wrap — the live container inherits the inert
/// default below unchanged. This protocol is kept because the fork/copy/free
/// *lifecycle* contract (a child's cache born from a copy, freed independently
/// on release) is still real and still unit-tested; only the "backed by actual
/// reusable compute" property is not currently true for any conformer. See
/// plan.md for why re-deriving a cheap prefix-reuse mechanism against the
/// pinned `mlx-swift-lm` dependency is an open question, not a settled fact.
///
/// The concept is abstracted behind this protocol (rather than any concrete
/// engine type) so the fork/copy/free contract is unit-testable without a GPU:
/// the suite substitutes a stub that records `copy()` invocations and its free
/// on release.
///
/// It is class-bound and `Sendable` so a session (an actor) can hold one across
/// isolation boundaries and free it deterministically by dropping its reference.
public protocol SessionKVCache: AnyObject, Sendable {
    /// Returns an independent copy of this cache — the fork seam.
    ///
    /// The returned cache begins equal to this one and then diverges: mutations
    /// to either do not affect the other. Every current conformer (including the
    /// live ``MLXFoundationModelsContainer``) is inert — see this protocol's
    /// documentation for why.
    ///
    /// - Returns: A new cache that starts as a copy of this one.
    func copy() -> any SessionKVCache
}

extension LoadedLLMContainer {
    /// The default KV cache for a new session over this model: an inert cache
    /// that holds nothing and frees nothing.
    ///
    /// Every current conformer — including the live ``MLXFoundationModelsContainer``
    /// (see its documentation) — inherits this inert default so a vended
    /// session always has a well-defined cache to own, copy on fork, and free
    /// on release, with no GPU dependency.
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
