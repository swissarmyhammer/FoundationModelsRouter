/// The gates one resident model container carries, held as a single value.
/// The set is per ``PoolEntry``: one container has one set of gates, and
/// every ``RoutedModel`` built over that container, from every ``Router``
/// on the pool, takes this same set. So two handles over one container
/// contend on one generation gate, whichever router made them. A second set
/// over an already-resident container is a defect.
///
/// The set holds the generation gate only. A fork is not counted: any number
/// of forks over one container can exist at once, and they serialize on the
/// generation gate when they generate.
///
/// The per-pass ``GenerationQueue`` is not in this set: the container makes
/// and owns it, and one resident container is one pool entry. It is a
/// different semaphore from ``generation``, because a turn holds this gate
/// while each of its passes waits in the queue.
package struct ResidentModelGates: Sendable {
    /// The per-container generation gate, a fair FIFO ``AsyncSemaphore`` at
    /// value `1`. Every session and fork over the container waits on it.
    let generation: AsyncSemaphore

    /// Mints a fresh set of gates. Call it once for each resident container.
    package init() {
        generation = AsyncSemaphore(value: 1)
    }
}
