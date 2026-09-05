/// The gates one resident model container carries, held as a single value.
/// The set is per ``PoolEntry``: one container has one set of gates, and
/// every ``RoutedModel`` built over that container, from every ``Router``
/// on the pool, takes this same set. So two handles over one container
/// contend on one generation gate, whichever router made them. A second set
/// over an already-resident container is a defect.
///
/// The set is minted at first load from the loading router's
/// `maxConcurrentForks`. That is the fork ceiling every later router over
/// the same container gets, whatever its own ceiling is.
package struct ResidentModelGates: Sendable {
    /// The per-container generation gate, a fair FIFO ``AsyncSemaphore`` at
    /// value `1`. Every session and fork over the container waits on it.
    let generation: AsyncSemaphore

    /// The per-container fork-admission gate, an ``AsyncSemaphore`` at value
    /// `maxConcurrentForks`. A fork past the ceiling awaits a free slot.
    let forkAdmission: AsyncSemaphore

    /// Mints a fresh set of gates. Call it once for each resident container.
    ///
    /// - Parameter maxConcurrentForks: The in-flight fork ceiling ``forkAdmission`` admits.
    package init(maxConcurrentForks: Int) {
        generation = AsyncSemaphore(value: 1)
        forkAdmission = AsyncSemaphore(value: maxConcurrentForks)
    }
}
