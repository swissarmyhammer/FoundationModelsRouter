import FoundationModelsExtras

/// The port that the host fills, so the ``RouterSessionDirectory`` can start
/// a new root session (ROUTER-8), so the host can restore a recorded one
/// through the same port, and so the host builds each fork with its own
/// surface (``forkSession(_:)``, D205). Router cannot
/// compose the tools of a session and does not know the agent catalog, so
/// the host makes each session; the directory only asks for one.
///
/// The host gives its launcher to the directory with
/// ``RouterSessionDirectory/use(launcher:)`` after it makes both objects,
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
    func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession

    /// Restores the recorded session `id`, with the tools that the host gives
    /// it. The directory does not call this for a send: a send to a recorded
    /// session that is not live only writes a file in its inbox (ROUTER-5).
    ///
    /// - Parameter id: The id of the recorded session.
    /// - Returns: The restored session.
    /// - Throws: `SessionDirectoryError.unknownSession(_:)` when no recorded
    ///   session has this id, or the error of the restore.
    func restoreSession(id: ULID) async throws -> any RoutedSession

    /// Builds the fork of `request` with the surface of the host (D205):
    /// the tools of the MCP servers and the folders of the client or of the
    /// source. ``RouterSessionDirectory/fork(_:)`` calls this when the
    /// directory has a launcher.
    ///
    /// The directory already mapped the cut and chose the id of the fork. The
    /// launcher builds the fork through the request
    /// (``SessionLaunchForkRequest/makeFork(tools:)``), one time, and
    /// returns that fork. It does not map the cut again, so the recording
    /// node of the fork and its ``SessionRecord/forkedAtHistoryOrdinal``
    /// agree with the request.
    ///
    /// The directory registers the fork and mails its first prompt only
    /// after this call returns. So no prompt of the fork runs before the
    /// host gave its surface, and the host holds the fork from its start.
    /// The launcher sends nothing to the fork.
    ///
    /// When this call throws, the directory refuses the fork: it registers
    /// nothing, closes a fork that the request built, and removes its
    /// recording node.
    ///
    /// A launcher that does not implement this operation gets the default
    /// of this protocol: the fork has the tools of the source
    /// (``SessionLaunchForkRequest/makeFork()``).
    ///
    /// - Parameter request: The source, the cut, the fork id, the folder and
    ///   the client of the fork, and the way to build it.
    /// - Returns: The fork that the request built.
    /// - Throws: The error of the host, which refuses the fork, or the error
    ///   of the build.
    func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession
}

extension SessionLauncher {
    /// See ``SessionLauncher/forkSession(_:)``. The default builds the fork
    /// with the tools of the source (``SessionLaunchForkRequest/makeFork()``),
    /// as a directory with no launcher does.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork that the request built.
    /// - Throws: The error of the build.
    public func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        try await request.makeFork()
    }
}
