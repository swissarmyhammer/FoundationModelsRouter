import FoundationModelsExtras
import FoundationModelsRouter

/// A ``SessionLauncher`` that refuses each start and each restore. A test
/// launcher conforms to it and writes only the operation that it tests, for
/// example ``SessionLauncher/forkSession(_:)``.
///
/// The unit tests and the public-surface tests share these refusals, so each
/// test launcher does not write the two operations again.
public protocol StartRefusingLauncher: SessionLauncher {}

extension StartRefusingLauncher {
    /// Throws `unknownAgent` for the agent of `request`: the launcher knows
    /// no agent.
    ///
    /// - Parameter request: The start request.
    /// - Returns: Nothing.
    /// - Throws: `SessionDirectoryError.unknownAgent` for the agent id of
    ///   `request`, or for ``StartRefusal/defaultAgentID`` when `request`
    ///   names no agent, with no near name.
    public func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
        throw SessionDirectoryError.unknownAgent(request.agentID ?? StartRefusal.defaultAgentID, nearNames: [])
    }

    /// Throws `unknownSession` for `id`: the launcher restores no session.
    ///
    /// - Parameter id: The session id.
    /// - Returns: Nothing.
    /// - Throws: `SessionDirectoryError.unknownSession` for `id`.
    public func restoreSession(id: ULID) async throws -> any RoutedSession {
        throw SessionDirectoryError.unknownSession(id)
    }
}

/// The values of the refusals of a ``StartRefusingLauncher``.
private enum StartRefusal {
    /// The agent id of the refusal of a start that names no agent: the
    /// default agent, which the launcher does not know either.
    static let defaultAgentID = "default"
}
