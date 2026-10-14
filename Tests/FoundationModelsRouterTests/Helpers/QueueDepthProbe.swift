import Metrics

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// A metrics factory that signals ``enqueued`` each time a queue makes a job
/// on a task that uses this factory: a task that binds it with
/// `withMetricsFactory`, or a task of a session that got it as its explicit
/// factory. The queue records its depth meter when it makes the job, and then
/// puts the job in its input in the same `submit` call, with no suspension
/// point between. Each other metric goes to the no-op handler.
///
/// The queue suites use it where no event of the router tells that a job
/// joined a queue: a call that submits with no `onQueued`.
final class QueueDepthProbe: MetricsFactory {
    /// Signalled once for each job that a queue of ``model`` made.
    let enqueued = AsyncSemaphore(value: 0)

    /// The model whose queue counts, or `nil` to count each queue.
    private let model: ModelRef?

    /// Makes a probe.
    ///
    /// - Parameter model: The model whose queue counts. The default, `nil`,
    ///   counts each queue.
    init(model: ModelRef? = nil) {
        self.model = model
    }

    /// Makes a counter that records nothing.
    ///
    /// - Parameters:
    ///   - label: The label of the counter.
    ///   - dimensions: The dimensions of the counter.
    /// - Returns: The no-op handler.
    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        NOOPMetricsHandler.instance
    }

    /// Makes a recorder that records nothing.
    ///
    /// - Parameters:
    ///   - label: The label of the recorder.
    ///   - dimensions: The dimensions of the recorder.
    ///   - aggregate: Whether the recorder aggregates its values.
    /// - Returns: The no-op handler.
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler {
        NOOPMetricsHandler.instance
    }

    /// Makes a timer that records nothing.
    ///
    /// - Parameters:
    ///   - label: The label of the timer.
    ///   - dimensions: The dimensions of the timer.
    /// - Returns: The no-op handler.
    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler {
        NOOPMetricsHandler.instance
    }

    /// Makes the depth meter of a queue that counts as a
    /// ``QueueDepthProbeMeter``, and each other meter as the no-op handler.
    ///
    /// - Parameters:
    ///   - label: The label of the meter.
    ///   - dimensions: The dimensions of the meter.
    /// - Returns: The meter.
    func makeMeter(label: String, dimensions: [(String, String)]) -> any MeterHandler {
        guard label == ExtrasTelemetry.MetricName.queueDepth, counts(dimensions) else {
            return NOOPMetricsHandler.instance
        }
        return QueueDepthProbeMeter(enqueued: enqueued)
    }

    /// Destroys nothing: no handler keeps a resource.
    ///
    /// - Parameter handler: The counter.
    func destroyCounter(_ handler: any CounterHandler) {}

    /// Destroys nothing: no handler keeps a resource.
    ///
    /// - Parameter handler: The recorder.
    func destroyRecorder(_ handler: any RecorderHandler) {}

    /// Destroys nothing: no handler keeps a resource.
    ///
    /// - Parameter handler: The timer.
    func destroyTimer(_ handler: any TimerHandler) {}

    /// Destroys nothing: no handler keeps a resource.
    ///
    /// - Parameter handler: The meter.
    func destroyMeter(_ handler: any MeterHandler) {}

    /// Whether the queue of a depth meter with `dimensions` counts.
    ///
    /// - Parameter dimensions: The dimensions of the depth meter.
    /// - Returns: `true` when no ``model`` is set, or when the queue is the
    ///   queue of ``model``.
    private func counts(_ dimensions: [(String, String)]) -> Bool {
        guard let model else { return true }
        return dimensions.contains { $0 == (ExtrasTelemetry.DimensionKey.modelRef, model.stringValue) }
    }
}

/// The depth meter of a queue that a ``QueueDepthProbe`` counts: each
/// increment is one job that the queue made, and signals ``enqueued``.
final class QueueDepthProbeMeter: MeterHandler {
    /// Signalled once for each increment.
    let enqueued: AsyncSemaphore

    /// Makes a meter that signals `enqueued`.
    ///
    /// - Parameter enqueued: The semaphore to signal for each increment.
    init(enqueued: AsyncSemaphore) {
        self.enqueued = enqueued
    }

    /// Ignores the value: only an increment is a job.
    ///
    /// - Parameter value: The value.
    func set(_ value: Int64) {}

    /// Ignores the value: only an increment is a job.
    ///
    /// - Parameter value: The value.
    func set(_ value: Double) {}

    /// Signals ``enqueued``: the queue made one job.
    ///
    /// - Parameter amount: The amount of the increment.
    func increment(by amount: Double) {
        enqueued.signal()
    }

    /// Ignores the decrement: a job ended.
    ///
    /// - Parameter amount: The amount of the decrement.
    func decrement(by amount: Double) {}
}
