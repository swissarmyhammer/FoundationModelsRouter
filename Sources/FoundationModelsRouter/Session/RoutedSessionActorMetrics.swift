import Metrics

/// The metrics of ``RoutedSessionActor``: its explicit metrics factory, or the
/// factory of `MetricsSystem` at each record call.
extension RoutedSessionActor {
    /// Gives this session an explicit metrics factory. Each later metric of
    /// the session, also a metric of its detached pump, goes to `factory`.
    ///
    /// - Parameter factory: The metrics factory to use from now on.
    func useMetricsFactory(_ factory: any MetricsFactory) {
        explicitMetricsFactory = factory
    }

    /// The metrics recorder for one record call of this session.
    ///
    /// Read it at the record call. It holds no metric, so a backend that the
    /// host bootstraps later still gets the value. The read is synchronous and
    /// adds no suspension point.
    var sessionMetrics: RouterMetrics {
        RouterMetrics(explicit: explicitMetricsFactory)
    }

    /// Records the count of the caller messages that wait in
    /// ``SessionOutbox/messages`` now.
    ///
    /// The post of a caller message and the take of a batch call it on this
    /// actor, each with no suspension point after its change of the queue. The
    /// delivery letter of an answer that only mail starts never waits when
    /// this actor reads the queue (``pendingMessages()``), so the count never
    /// holds it.
    func recordMessageQueueDepth() {
        sessionMetrics.recordSessionQueueDepth(waiting: outbox.messages.depth.waiting)
    }
}
