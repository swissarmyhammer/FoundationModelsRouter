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

    /// Runs one job of the pump with the explicit logger of this session as
    /// ``RouterTelemetry/pumpJobLogger``.
    ///
    /// The session logs its own records through ``sessionLogger(_:)``. Code
    /// that the job calls and that has no session to ask logs through
    /// ``RouterTelemetry/makeLogger(_:)``, for example the mapper and the
    /// recorder of the transcript recording. The pump is a detached task, so
    /// without this binding such a record goes to the global logging system,
    /// not to the explicit logger of the session. The job reads the logger
    /// when it starts, so a logger that the caller gives later applies to the
    /// next job.
    ///
    /// The binding adds no suspension point: the job stays on this actor.
    ///
    /// - Parameter job: The job of the pump.
    /// - Returns: The value of `job`.
    func withSessionLogger<Value>(_ job: nonisolated(nonsending) () async -> Value) async -> Value {
        guard let explicitLogger else { return await job() }
        return await RouterTelemetry.pumpJobLogger.withValue(explicitLogger) { await job() }
    }
}
