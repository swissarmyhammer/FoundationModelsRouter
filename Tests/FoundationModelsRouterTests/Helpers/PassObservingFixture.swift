import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// The parts one test observes through a ``PassObservingModel``, and the
/// container whose backends run over them.
///
/// This is the one fixture of the queue suites. A suite that needs more than
/// one container over the same parts calls ``makeContainer()``: each
/// container owns a ``GenerationQueue`` of its own.
struct PassObservingFixture: Sendable {
    /// The observer each pass reports its entry and its exit to.
    let observer = ConcurrencyPeakObserver()

    /// The latch each pass waits on. It is closed until the test opens it.
    let latch = RunLatch()

    /// The log of the passes.
    let passes = ObservedPassLog()

    /// The model every container of this fixture runs over.
    let model: PassObservingModel

    /// The container whose backends share one queue.
    let container: LiveBackendContainer<PassObservingModel>

    /// Makes a fixture with a closed latch.
    ///
    /// - Parameters:
    ///   - toolRounds: How many passes of one turn call a tool, in a session
    ///     that mounts one. The default is none.
    ///   - step: The semaphore each pass waits on after the latch, or `nil`
    ///     (the default) for no step.
    init(toolRounds: Int = 0, step: AsyncSemaphore? = nil) {
        model = PassObservingModel(
            observer: observer, latch: latch, passes: passes, step: step, toolRounds: toolRounds)
        container = LiveBackendContainer(model: model)
    }

    /// The queue of ``container``.
    var queue: GenerationQueue { container.generationQueue }

    /// A new container over the parts of this fixture, with a queue of its
    /// own.
    ///
    /// - Returns: The container.
    func makeContainer() -> LiveBackendContainer<PassObservingModel> {
        LiveBackendContainer(model: model)
    }
}
