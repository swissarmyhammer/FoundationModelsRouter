import Metrics

/// Records the metrics of the router through swift-metrics, with the names
/// and the dimension keys of ``RouterTelemetry``.
///
/// ## Lifetime
///
/// No metric is stored. Each record call makes its metric at that time, from
/// the explicit factory when there is one, else from `MetricsSystem.factory`.
/// A metric keeps the factory of the time that it was made. So a stored metric
/// misses a backend that the host bootstraps later, and a test capture that
/// starts later. `MetricsSystem.factory` reads the task-local factory of
/// `withMetricsFactory` first. A detached task does not get that task-local,
/// so an owner whose work runs on a detached task (the pump of a session)
/// keeps an explicit factory and gives it here.
///
/// Each record call is synchronous and adds no suspension point.
///
/// ## Dimensions
///
/// A dimension value is a model reference, a slot or a trigger. It never
/// carries the content of the caller, and each value set is bounded. See
/// ``RouterTelemetry/MetricDimension``.
struct RouterMetrics: Sendable {
    /// The factory of the owner, or `nil` to read `MetricsSystem.factory` at
    /// each record call.
    let explicitFactory: (any MetricsFactory)?

    /// Makes a recorder.
    ///
    /// - Parameter explicitFactory: The factory of the owner, or `nil` (the
    ///   default) to read `MetricsSystem.factory` at each record call.
    init(explicit explicitFactory: (any MetricsFactory)? = nil) {
        self.explicitFactory = explicitFactory
    }

    /// The factory that a record call makes its metric from now.
    private var factory: any MetricsFactory {
        explicitFactory ?? MetricsSystem.factory
    }

    /// Records one generation call: its tokens in and out, and its output
    /// rate.
    ///
    /// A call with no duration records no rate, because the rate of a call
    /// that took no time has no value.
    ///
    /// - Parameters:
    ///   - tokensIn: The tokens the call fed the model.
    ///   - tokensOut: The tokens the call generated.
    ///   - duration: How long the call ran.
    ///   - model: The model of the call.
    ///   - slot: The slot of the model.
    func recordGenerationCall(tokensIn: Int, tokensOut: Int, duration: Duration, model: ModelRef, slot: ModelSlot) {
        let dimensions = Self.dimensions(model: model, slot: slot)
        Counter(label: RouterTelemetry.MetricName.generationTokensIn, dimensions: dimensions, factory: factory)
            .increment(by: tokensIn)
        Counter(label: RouterTelemetry.MetricName.generationTokensOut, dimensions: dimensions, factory: factory)
            .increment(by: tokensOut)
        let seconds = duration.seconds
        guard seconds > 0 else { return }
        Recorder(
            label: RouterTelemetry.MetricName.generationTokensPerSecond, dimensions: dimensions, factory: factory
        ).record(Double(tokensOut) / seconds)
    }

    /// Records the time from the start of the submission of a model call to
    /// its first observable progress.
    ///
    /// - Parameters:
    ///   - duration: The time to the first progress.
    ///   - model: The model of the call.
    ///   - slot: The slot of the model.
    func recordTimeToFirstToken(_ duration: Duration, model: ModelRef, slot: ModelSlot) {
        Metrics.Timer(
            label: RouterTelemetry.MetricName.timeToFirstToken, dimensions: Self.dimensions(model: model, slot: slot),
            factory: factory
        ).record(duration: duration)
    }

    /// Records the duration of one model load.
    ///
    /// - Parameters:
    ///   - duration: How long the load ran.
    ///   - model: The model the load loaded.
    ///   - slot: The slot the model fills.
    func recordLoad(duration: Duration, model: ModelRef, slot: ModelSlot) {
        Metrics.Timer(
            label: RouterTelemetry.MetricName.loadDuration, dimensions: Self.dimensions(model: model, slot: slot),
            factory: factory
        ).record(duration: duration)
    }

    /// Sets the gauge of the bytes that the models of the pool use now.
    ///
    /// The gauge has no dimension. Each router over one pool reads the same
    /// footprint of that pool, so two routers over one pool write the same
    /// value, and the gauge holds that value whichever of them wrote last.
    ///
    /// - Parameter bytes: The total bytes of the footprint of the pool.
    func recordResidentBytes(_ bytes: Int64) {
        Gauge(label: RouterTelemetry.MetricName.residentBytes, factory: factory).record(bytes)
    }

    /// Records the count of the caller messages that wait in the queue of a
    /// session.
    ///
    /// The metric is a recorder (a distribution) with no dimension, and not a
    /// gauge. A session dimension would make a label set with no bound, and
    /// a gauge with no dimension would hold only the value of the session
    /// that wrote last. The distribution of the depths of all the sessions
    /// has neither problem.
    ///
    /// - Parameter waiting: The count of the waiting caller messages.
    func recordSessionQueueDepth(waiting: Int) {
        Recorder(label: RouterTelemetry.MetricName.sessionQueueDepth, factory: factory).record(waiting)
    }

    /// Sets the gauge of the submissions that wait in the generation queue of
    /// a model.
    ///
    /// Each session over one model submits to the one queue of that model,
    /// so each writer of one gauge reads the same queue.
    ///
    /// - Parameters:
    ///   - waiting: The count of the waiting submissions.
    ///   - model: The model of the queue.
    func recordGenerationQueueWaiting(_ waiting: Int, model: ModelRef) {
        Gauge(
            label: RouterTelemetry.MetricName.generationQueueWaiting,
            dimensions: [(RouterTelemetry.MetricDimension.modelRef, model.stringValue)], factory: factory
        ).record(waiting)
    }

    /// Counts one compaction.
    ///
    /// - Parameter trigger: What asked for the compaction.
    func recordCompaction(trigger: RouterTelemetry.CompactionTrigger) {
        Counter(
            label: RouterTelemetry.MetricName.compactionCount,
            dimensions: [(RouterTelemetry.MetricDimension.compactionTrigger, trigger.rawValue)], factory: factory
        ).increment()
    }

    /// The dimensions of a metric of one model in one slot.
    ///
    /// - Parameters:
    ///   - model: The model.
    ///   - slot: The slot of the model.
    /// - Returns: The model reference and the slot.
    private static func dimensions(model: ModelRef, slot: ModelSlot) -> [(String, String)] {
        [
            (RouterTelemetry.MetricDimension.modelRef, model.stringValue),
            (RouterTelemetry.MetricDimension.slot, slot.rawValue),
        ]
    }
}
