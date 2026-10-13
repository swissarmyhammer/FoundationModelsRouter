import Metrics

/// The metrics of ``RoutedSessionActor``: its explicit metrics factory, or the
/// factory of `MetricsSystem` at each record call.
extension RoutedSessionActor {
    /// Gives this session an explicit metrics factory. Each later metric of
    /// the session, also a metric of its detached pump, goes to `factory`.
    ///
    /// - Parameter factory: The metrics factory to use from now on.
    func useMetricsFactory(_ factory: any MetricsFactory) {
        explicitMetricsFactoryState.withLock { $0 = factory }
    }

    /// The metrics recorder for one record call of this session.
    ///
    /// Read it at the record call. It holds no metric, so a backend that the
    /// host bootstraps later still gets the value. The read is synchronous and
    /// adds no suspension point. It is nonisolated, so the output of the
    /// session can record a metric from any task.
    nonisolated var sessionMetrics: RouterMetrics {
        RouterMetrics(explicit: explicitMetricsFactory)
    }

    /// Runs one job of the pump with the explicit metrics factory of this
    /// session as the task-local metrics factory.
    ///
    /// The router records its own metrics through ``sessionMetrics``. A
    /// dependency records its metrics through `MetricsSystem.factory`, for
    /// example the tool-call counter and timer of FoundationModelsExtras. The
    /// pump is a detached task, so without this binding such a metric goes to
    /// the global factory, not to the explicit factory of the session. The job
    /// reads the factory when it starts, so a factory that the caller gives
    /// later applies to the next job.
    ///
    /// `withMetricsFactory` is `nonisolated(nonsending)`: the job stays on
    /// this actor and gets no other suspension point.
    ///
    /// - Parameter job: The job of the pump.
    /// - Returns: The value of `job`.
    func withSessionMetricsFactory<Value>(_ job: nonisolated(nonsending) () async -> Value) async -> Value {
        guard let explicitMetricsFactory else { return await job() }
        return await withMetricsFactory(explicitMetricsFactory, job)
    }

    /// Records the count of the mail that waits in ``SessionOutbox/queue``
    /// now, by mail kind (`mailbox.md`, section 5, problem 18).
    ///
    /// The arrival of mail (``mail(_:)``) and each take of the pump call it
    /// on this actor. The arrival records it in a task of its own, so a
    /// record can come after a later change of the queue; each record gives
    /// the count at the time it runs.
    func recordMailQueueDepth() {
        sessionMetrics.recordMailQueueDepth(outbox.queue.depthByKind)
    }
}
