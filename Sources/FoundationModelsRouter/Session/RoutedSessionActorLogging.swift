import Logging

/// The logger of ``RoutedSessionActor``: its explicit logger, or a logger of
/// the module for each call.
extension RoutedSessionActor {
    /// Gives this session an explicit logger. Each later log record of the
    /// session, also a record of its detached pump, goes to `logger`.
    ///
    /// - Parameter logger: The logger to use from now on.
    func useLogger(_ logger: Logger) {
        explicitLogger = logger
    }

    /// The logger for one log call of this session.
    ///
    /// Call it at the log call. It makes a new logger of the module when the
    /// session has no explicit logger, so a backend that the host bootstraps
    /// later still gets the record. The call is synchronous and adds no
    /// suspension point.
    ///
    /// - Parameter category: The area of the router that logs.
    /// - Returns: ``RouterTelemetry/logger(_:explicit:)`` over
    ///   ``explicitLogger``.
    func sessionLogger(_ category: RouterTelemetry.LogCategory) -> Logger {
        RouterTelemetry.logger(category, explicit: explicitLogger)
    }
}
