import Foundation

/// An error of a ``RoutedSession`` that refuses a call.
public enum RoutedSessionError: Error, Sendable, Equatable, LocalizedError {
    /// A tool body inside an answer of the session `sessionID` waited, in
    /// band, for an answer of that same session (task ^hga4td7).
    ///
    /// The pump of a session runs one answer at a time. The answer that the
    /// tool body waits for can start only after the answer of the tool body
    /// ends, and that answer waits for the tool body. So the wait could never
    /// end, and the session refuses it at once. A wait for another session,
    /// on the same model or on another model, is not refused. A background
    /// run is not in band, so its wait is not refused.
    case inBandWaitForOwnSession(sessionID: ULID)

    /// A localized message that describes the error.
    public var errorDescription: String? {
        switch self {
        case .inBandWaitForOwnSession(let sessionID):
            """
            A tool body inside an answer of session \(sessionID) waited for another answer of session \
            \(sessionID). That answer can start only after the answer of the tool body ends, so the wait \
            could never end. Start the work from a background tool, and let its result come back as mail, \
            or wait for work of a different session.
            """
        }
    }
}
