import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// The parts one test observes through a ``PassObservingModel``, and the
/// container whose backends run over them.
///
/// This is the one fixture of the queue suites. A suite that needs more than
/// one container over the same parts calls ``makeContainer()``: each such
/// container names no queue until a resolve gives it the queue of its pool
/// entry.
struct PassObservingFixture: Sendable {
    /// The observer each pass reports its entry and its exit to.
    let observer = ConcurrencyPeakObserver()

    /// The latch each pass waits on. It is closed until the test opens it.
    let latch = RunLatch()

    /// The log of the passes.
    let passes = ObservedPassLog()

    /// The model every container of this fixture runs over.
    let model: PassObservingModel

    /// The queue of ``container``. It stands in for the queue of a pool entry
    /// in a test that uses ``container`` outside a pool.
    let queue = GenerationQueue()

    /// The container whose backends share ``queue``.
    let container: LiveBackendContainer<PassObservingModel>

    /// Makes a fixture with a closed latch.
    ///
    /// - Parameters:
    ///   - toolRounds: How many passes of one submission call a tool, in a session
    ///     that mounts one. The default is none.
    ///   - step: The semaphore each pass waits on after the latch, or `nil`
    ///     (the default) for no step.
    init(toolRounds: Int = 0, step: AsyncSemaphore? = nil) {
        model = PassObservingModel(
            observer: observer, latch: latch, passes: passes, step: step, toolRounds: toolRounds)
        container = LiveBackendContainer(model: model, generationQueue: queue)
    }

    /// A new container over the parts of this fixture. It names no queue
    /// until a resolve gives it the queue of its pool entry.
    ///
    /// - Returns: The container.
    func makeContainer() -> LiveBackendContainer<PassObservingModel> {
        LiveBackendContainer(model: model)
    }
}
