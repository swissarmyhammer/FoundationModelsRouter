import Metrics

@testable import FoundationModelsRouter

extension RoutedSession {
    /// Gives `factory` to this session as its explicit metrics factory, so
    /// that each metric of the session, also a metric of its detached pump,
    /// goes to `factory`.
    ///
    /// - Parameter factory: The metrics factory of a capture,
    ///   `TelemetryCapture.Context.metricsFactory`.
    func useCaptureMetrics(for factory: any MetricsFactory) async {
        await (self as! RoutedSessionActor).useMetricsFactory(factory)
    }

    /// The model reference of this session, in canonical string form: the
    /// value of the `model.ref` dimension of each metric of the session.
    nonisolated var modelRefDimension: String {
        (self as! RoutedSessionActor).model.stringValue
    }
}
