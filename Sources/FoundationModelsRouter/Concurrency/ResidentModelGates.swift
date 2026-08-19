/// The gates one resident model container carries, held as a single value.
///
/// A gate belongs to the resident container, not to the handle over it. One
/// container has one set of gates, and every ``RoutedModel`` built over that
/// container takes this same set. Two handles over one container therefore
/// contend on one generation gate, whether ``Router/resolve(profile:reporting:)``
/// built them or a suite built them by hand.
///
/// The type exists to make that rule structural. Before it, the handle
/// initializer took each gate on its own with a `nil` default, and `nil` minted
/// a fresh gate. A caller who built two handles over one container and named no
/// gate got two gates, so the two handles could never contend and two
/// generations ran inside the one container at once. Nothing in the code said
/// so. ``RoutedModel``'s initializer now takes this one value and has no default
/// for it, so a second set of gates over a container that already has one cannot
/// appear by accident: a caller must write it.
///
/// The gate is a throughput constraint and not a safety one. The resident
/// container gives exclusive access on its own, so two generations over it stay
/// correct and are only slower than one. What the set protects is the
/// serialization the caller asked for, which the old default took away with no
/// signal.
///
/// `package` rather than `internal`, and deliberately not `public`: the plain
/// `FoundationModelsRouterRealModelSupport` target's `RealModelHarness` mints
/// the one gate set its hand-built profile's two generation handles share, and
/// a plain target cannot use `@testable import` (task ^cvsh3m9). `package`
/// stops at this package's own boundary, so no consumer outside the package
/// can mint a second set over an already-resident container.
package struct ResidentModelGates: Sendable {
    /// The per-container generation gate, a fair FIFO ``AsyncSemaphore`` at
    /// value `1`.
    ///
    /// Every ``RoutedSession`` vended from any handle over the container — each
    /// root session and all of its forks — waits on this one gate, so their
    /// generations serialize rather than interleave. Only the
    /// generation-session surface acquires it; the embedding handle never does.
    let generation: AsyncSemaphore

    /// The per-container fork-admission gate, a fair FIFO ``AsyncSemaphore`` at
    /// value `maxConcurrentForks`.
    ///
    /// At most `maxConcurrentForks` fork sessions over the container may be in
    /// flight at once. A ``RoutedSession/fork(workingDirectory:)`` past the
    /// ceiling awaits a free slot, which is freed when a fork is released. This
    /// caps the K× prefix-KV cost of copying the parent's cache on each fork.
    /// Only the generation-session fork surface acquires it.
    let forkAdmission: AsyncSemaphore

    /// Mints a fresh set of gates for a container that has just become
    /// resident.
    ///
    /// Call this once for each resident container, and hand the result to every
    /// handle built over that container. A second call for the same container
    /// gives a second set, which is the defect the type exists to make visible.
    ///
    /// - Parameter maxConcurrentForks: The in-flight fork ceiling
    ///   ``forkAdmission`` admits (the router's `maxConcurrentForks`).
    package init(maxConcurrentForks: Int) {
        generation = AsyncSemaphore(value: 1)
        forkAdmission = AsyncSemaphore(value: maxConcurrentForks)
    }
}
