import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The parts one test observes through a ``PassObservingModel``, and the
/// container whose backends run over them.
///
/// This is the one fixture of the suites of the generation lock. A suite that
/// needs more than one container over the same parts calls
/// ``makeContainer()``. Each container runs over the one model, and thus over
/// the one ``FIFOGenerationLock`` of the model.
struct PassObservingFixture: Sendable {
    /// The observer each pass reports its entry and its exit to.
    let observer = ConcurrencyPeakObserver()

    /// The lock of the model: each pass holds it while it generates, as a
    /// pass of an MLX model holds the lock of its container.
    let lock = FIFOGenerationLock()

    /// The latch each pass waits on. It is closed until the test opens it.
    let latch = RunLatch()

    /// The log of the passes.
    let passes = ObservedPassLog()

    /// The model every container of this fixture runs over.
    let model: PassObservingModel

    /// The container whose backends run over ``model``.
    let container: LiveBackendContainer<PassObservingModel>

    /// Makes a fixture with a closed latch.
    ///
    /// - Parameters:
    ///   - toolRounds: How many passes of one submission call a tool, in a session
    ///     that mounts one. The default is none.
    ///   - step: The semaphore each pass waits on after the latch, or `nil`
    ///     (the default) for no step.
    ///   - holdsAfterFirstOutput: Whether a pass that answers sends the
    ///     prefix of its answer before it holds. The default is `false`.
    init(toolRounds: Int = 0, step: AsyncSemaphore? = nil, holdsAfterFirstOutput: Bool = false) {
        model = PassObservingModel(
            observer: observer, lock: lock, latch: latch, passes: passes, step: step, toolRounds: toolRounds,
            holdsAfterFirstOutput: holdsAfterFirstOutput)
        container = LiveBackendContainer(model: model)
    }

    /// Waits until the first pass entered ``model``, or until `task` ended
    /// (rule T1). When `task` ended first, the wait throws
    /// ``FailureEventCameFirst``.
    ///
    /// In a test that passes, `task` must not end before the pass entered:
    /// for example `task` is the answer of that pass, and the latch holds
    /// the pass.
    ///
    /// - Parameters:
    ///   - task: The task whose end is the failure event.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when `task` ended first, or
    ///   ``ConditionNeverHeld`` when the test was cancelled first.
    func waitUntilTheFirstPassEntered<Success: Sendable, Failure: Error>(
        endingOnEndOf task: Task<Success, Failure>, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let observer = observer
        try await RecordedWaitResult.wait(
            for: { try await observer.waitUntil { $0.entered == 1 } }, endingOnEndOf: task,
            sourceLocation: sourceLocation)
    }

    /// A new container over the parts of this fixture.
    ///
    /// - Returns: The container.
    func makeContainer() -> LiveBackendContainer<PassObservingModel> {
        LiveBackendContainer(model: model)
    }
}
