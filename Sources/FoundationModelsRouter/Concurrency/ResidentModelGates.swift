/// The gates one resident model container carries, held as a single value.
/// One container has one set of gates, and every ``RoutedModel`` built over
/// that container must take this same set, so two handles over one container
/// contend on one generation gate. A second set over an already-resident
/// container is a defect.
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
