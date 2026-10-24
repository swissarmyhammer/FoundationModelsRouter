import FoundationModelsExtras
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

    /// Records one generation call: its tokens in, cached and out, its whole
    /// time, its prefill and decode times, and its decode rate.
    ///
    /// The rate is the generated tokens over the decode time alone (task
    /// ^e5kyhwb): the prefill, the wait for the lock of the model and the
    /// tool bodies are not in it. Each call records its whole time (task ^0m997jr). A
    /// call whose first output token the session did not see records no
    /// prefill, no decode time and no rate, and a call with no decode time
    /// records no rate, because the rate of no time has no value. A call
    /// whose backend reports no cache count records no cached tokens.
    ///
    /// - Parameters:
    ///   - tokensIn: The tokens the call fed the model.
    ///   - tokensCached: The part of `tokensIn` the prompt cache reused, or
    ///     `nil` when the backend reports no cache count.
    ///   - tokensOut: The tokens the call generated.
    ///   - timing: The prefill and the decode time of the call.
    ///   - duration: The whole time of the call.
    ///   - model: The model of the call.
    ///   - slot: The slot of the model.
    func recordGenerationCall(
        tokensIn: Int, tokensCached: Int?, tokensOut: Int, timing: GenerationCallTiming, duration: Duration,
        model: ModelRef, slot: ModelSlot
    ) {
        let dimensions = Self.dimensions(model: model, slot: slot)
        Metrics.Timer(
            label: RouterTelemetry.MetricName.generationCallDuration, dimensions: dimensions, factory: factory
        ).record(duration: duration)
        recordTiming(timing, dimensions: dimensions)
        Counter(label: RouterTelemetry.MetricName.generationTokensIn, dimensions: dimensions, factory: factory)
            .increment(by: tokensIn)
        if let tokensCached {
            Counter(label: RouterTelemetry.MetricName.generationTokensCached, dimensions: dimensions, factory: factory)
                .increment(by: tokensCached)
        }
        Counter(label: RouterTelemetry.MetricName.generationTokensOut, dimensions: dimensions, factory: factory)
            .increment(by: tokensOut)
        guard let seconds = timing.decodeTime?.seconds, seconds > 0 else { return }
        Recorder(
            label: RouterTelemetry.MetricName.generationTokensPerSecond, dimensions: dimensions, factory: factory
        ).record(Double(tokensOut) / seconds)
    }

    /// Records the prefill and the decode time of one generation call, each
    /// one that the session saw.
    ///
    /// - Parameters:
    ///   - timing: The prefill and the decode time of the call.
    ///   - dimensions: The model and the slot of the call.
    private func recordTiming(_ timing: GenerationCallTiming, dimensions: [(String, String)]) {
        recordTimer(
            ifPresent: timing.timeToFirstToken, label: RouterTelemetry.MetricName.generationCallTimeToFirstToken,
            dimensions: dimensions)
        recordTimer(
            ifPresent: timing.decodeTime, label: RouterTelemetry.MetricName.generationCallDecodeTime,
            dimensions: dimensions)
    }

    /// Records `duration` on the timer `label`, and nothing when there is no
    /// duration.
    ///
    /// - Parameters:
    ///   - duration: The time to record, or `nil` when the session saw none.
    ///   - label: The metric name of the timer.
    ///   - dimensions: The model and the slot of the call.
    private func recordTimer(ifPresent duration: Duration?, label: String, dimensions: [(String, String)]) {
        guard let duration else { return }
        Metrics.Timer(label: label, dimensions: dimensions, factory: factory).record(duration: duration)
    }

    /// Records the time from the start of a submission to its first
    /// observable progress: one value for each submission
    /// (``RouterTelemetry/MetricName/submissionTimeToFirstToken``). The time
    /// of each generation call is a part of
    /// ``recordGenerationCall(tokensIn:tokensCached:tokensOut:timing:duration:model:slot:)``.
    ///
    /// - Parameters:
    ///   - duration: The time to the first progress.
    ///   - model: The model of the submission.
    ///   - slot: The slot of the model.
    func recordSubmissionTimeToFirstToken(_ duration: Duration, model: ModelRef, slot: ModelSlot) {
        Metrics.Timer(
            label: RouterTelemetry.MetricName.submissionTimeToFirstToken,
            dimensions: Self.dimensions(model: model, slot: slot), factory: factory
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

    /// Records the count of the mail that waits in the mail queue of a
    /// session, one value for each mail kind.
    ///
    /// The metric is a recorder (a distribution) with the one dimension
    /// `mail.kind`, and not a gauge. A session dimension would make a label
    /// set with no bound, and a gauge would hold only the value of the
    /// session that wrote last. The distribution of the depths of all the
    /// sessions has neither problem. Each call records each kind of
    /// `MailKind`, also a kind with no waiting mail (value 0), so each
    /// distribution has one value for each record call.
    ///
    /// - Parameter depthByKind: The count of the queued mail of each kind. A
    ///   kind with no key has no waiting mail.
    func recordMailQueueDepth(_ depthByKind: [MailKind: Int]) {
        for kind in MailKind.allCases {
            Recorder(
                label: RouterTelemetry.MetricName.sessionQueueDepth,
                dimensions: [(RouterTelemetry.MetricDimension.mailKind, kind.rawValue)], factory: factory
            ).record(depthByKind[kind, default: 0])
        }
    }

    /// Records the duration of one pause of the mail queue of a session for
    /// a compaction: from the pause to the resume. The timer has no
    /// dimension.
    ///
    /// - Parameter duration: How long the queue was paused.
    func recordMailQueuePause(_ duration: Duration) {
        Metrics.Timer(label: RouterTelemetry.MetricName.mailQueuePauseDuration, factory: factory)
            .record(duration: duration)
    }

    /// Counts the mail that ended with the terminal event
    /// ``SessionEvent/cancelled(_:)``. The counter has no dimension.
    ///
    /// - Parameter count: How many mail ended so. A call with `0` records
    ///   nothing.
    func recordCancelledMail(_ count: Int) {
        guard count > 0 else { return }
        Counter(label: RouterTelemetry.MetricName.mailCancelled, factory: factory).increment(by: count)
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
