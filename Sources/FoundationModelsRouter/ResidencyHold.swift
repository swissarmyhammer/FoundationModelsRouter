/// The reference-counted claim on one resolved residency.
///
/// ``Router/resolve(profile:reporting:)`` mints one hold for each residency it
/// grants, and hands that one instance to all three ``RoutedModel`` handles.
/// The ``LanguageModelProfile`` needs none of its own, because it holds those
/// three handles strongly. The residency therefore lives exactly as long as the
/// last of those objects, and not as long as the profile object alone: a tool
/// that takes only a handle — see `EmbedTool` — keeps its model resident after
/// the profile object is gone.
///
/// The hold stores the pool and the token and nothing else. It refers to no
/// router, no profile, and no handle, so a hold can never close a reference
/// cycle with the objects that store it, and it outlives the router that
/// resolved it without harm.
///
/// It is `package` rather than internal because the `package` initializer of
/// ``RoutedModel`` takes one.
package final class ResidencyHold: Sendable {
    /// The pool that holds the residency's charges.
    private let pool: ModelPool

    /// The router-minted, never-reused token that identifies the residency.
    private let token: ULID

    /// Creates the one hold on a residency.
    ///
    /// - Parameters:
    ///   - pool: The pool that holds the residency's charges.
    ///   - token: The token that identifies the residency.
    init(pool: ModelPool, token: ULID) {
        self.pool = pool
        self.token = token
    }

    /// Queues the residency for release when the last reference is dropped.
    ///
    /// `deinit` runs on whatever thread dropped that reference and cannot
    /// `await` the pool, so it appends the token to the pool's pending queue
    /// synchronously. Every resolve over the pool drains that queue before it
    /// measures the host budget, so the freed bytes reach the very first
    /// measurement instead of racing it.
    deinit {
        pool.enqueuePendingRelease(token)
    }
}
