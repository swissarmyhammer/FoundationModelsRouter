import FoundationModelsExtras

/// The port that the host fills, so the ``RouterSessionDirectory`` can start
/// a new root session and restore a recorded one (ROUTER-8). Router cannot
/// compose the tools of a session and does not know the agent catalog, so
/// the host makes each session; the directory only asks for one.
///
/// The host gives its launcher to the directory with
/// ``RouterSessionDirectory/useLauncher(_:)`` after it makes both objects,
/// and ``RouterSessionDirectory/shutdown()`` releases it again: the directory
/// holds the launcher, and the launcher makes surfaces that hold the
/// directory. With no launcher, ``RouterSessionDirectory/start(_:)`` throws
/// `SessionDirectoryError.noLauncher`.
///
/// **Resolution.** The launcher resolves what the request leaves open. With
/// no `workingDirectory`, the folder is the folder of `startedBy` (AG-5).
/// With no `agentID`, the agent is the `AGENT.md` of the folder, else the
/// default agent (D71). An agent id that names no agent throws
/// `SessionDirectoryError.unknownAgent(_:nearNames:)`, with the ids of the
/// agents whose names are near. The session that the launcher returns holds
/// the resolved agent id in its ``SessionConfiguration/agentID``, and Router
/// stores only that id (ROUTER-1); it never resolves one.
///
/// **The facts of the request.** The directory registers a session when
/// ``RoutedModel/makeSession(configuration:)`` vends it, and that
/// registration sends the one `started` event of the session. So the facts
/// of the request must be in the session before it registers: the launcher
/// copies `tags`, `title`, `startedBy`, `origin` and `requestedByClient`
/// from the request into the ``SessionConfiguration`` it vends with. A
/// session that lacks one of them still gets it, from
/// ``RouterSessionDirectory/start(_:)``, but then `started` goes out without
/// it and a `factsChanged` follows.
///
/// **The session.** The directory holds each session weakly, so the
/// launcher, or the host behind it, keeps the session it returns alive.
/// The directory sends the first message of the request itself; the
/// launcher sends nothing to the session.
public protocol SessionLauncher: Sendable {
    /// Makes a new root session for `request`, with the resolved agent and
    /// folder and the facts of the request.
    ///
    /// - Parameter request: The start request, exactly as the directory got
    ///   it: a nil agent and a nil folder stay nil.
    /// - Returns: The new session.
    /// - Throws: `SessionDirectoryError.unknownAgent(_:nearNames:)` when the
    ///   agent id names no agent, `SessionDirectoryError.notADirectory(_:)`
    ///   when the folder is not a folder, or the error of the host.
    func launchRootSession(_ request: SessionStartRequest) async throws -> any RoutedSession

    /// Restores the recorded session `id`, with the tools that the host gives
    /// it, so a message can reach a session that is not live (ROUTER-5).
    ///
    /// - Parameter id: The id of the recorded session.
    /// - Returns: The restored session.
    /// - Throws: `SessionDirectoryError.unknownSession(_:)` when no recorded
    ///   session has this id, or the error of the restore.
    func restoreSession(_ id: ULID) async throws -> any RoutedSession
}
