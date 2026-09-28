import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

extension TelemetryCapture.Context {
    /// Expects that this capture holds a log record whose message contains
    /// `fragment` and whose metadata holds each value of `metadata`.
    ///
    /// Shared by every suite that pins a loud log signal (for example
    /// `TranscriptEntryMapperTests`' degradation warnings and
    /// `TranscriptReconstructionTests`' duplicate-entry-id warning), so the
    /// read-back of the log records lives in one place.
    ///
    /// The records come from `TelemetryCapture.run(forbidding:sourceLocation:_:)`,
    /// which keeps the records of its own task only. Thus a test that runs in
    /// parallel with other tests sees only its own records. A log call on a
    /// detached task, for example the pump of a session, reaches the capture
    /// only through an explicit logger: give ``logger`` to the session with
    /// ``RoutedSession/useCaptureLogger(_:)`` first.
    ///
    /// - Parameters:
    ///   - fragment: The text that the message of the record must contain.
    ///   - metadata: The metadata values that the record must hold, by
    ///     ``RouterTelemetry/LogMetadataKey``. The text of the value of the
    ///     record must contain each value.
    ///   - sourceLocation: The source location that the issue names.
    func expectLogged(
        containing fragment: String,
        metadata: [String: String] = [:],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let matches = logRecords.contains { record in
            "\(record.message)".contains(fragment)
                && metadata.allSatisfy { key, value in
                    record.metadata[key].map { "\($0)".contains(value) } ?? false
                }
        }
        #expect(
            matches,
            "no log record contains \"\(fragment)\" with the metadata \(metadata); the records are \(logRecords)",
            sourceLocation: sourceLocation
        )
    }
}

extension RoutedSession {
    /// Gives `logger` to this session as its explicit logger, so that each
    /// log record of the session, also a record of its detached pump, goes
    /// to `logger`.
    ///
    /// - Parameter logger: The logger of a capture,
    ///   `TelemetryCapture.Context.logger`.
    func useCaptureLogger(_ logger: Logger) async {
        await (self as! RoutedSessionActor).useLogger(logger)
    }
}
