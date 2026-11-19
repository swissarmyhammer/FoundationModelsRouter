import FoundationModelsExtras

/// The port that the host fills, so the ``RouterSessionDirectory`` can start
/// a new root session (ROUTER-8), so the host can restore a recorded one
/// through the same port, so the host builds each fork with its own
/// surface (``forkSession(_:)``, D205), and so the host gives the model of
/// each imported session (``importTarget(for:)``, D209 (h)). Router cannot
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
    /// (``SessionLaunchForkRequest/makeFork(tools:additionalDirectories:)``
    /// or ``SessionLaunchForkRequest/makeFork(tools:)``), one time, and
    /// returns that fork. It does not map the cut again, so the recording
    /// node of the fork and its ``SessionRecord/forkedAtHistoryOrdinal``
    /// agree with the request.
    ///
    /// The directory calls this operation in the task of the caller of
    /// ``RouterSessionDirectory/fork(_:)``. No `Task {}`, no `Task.detached`
    /// and no other task comes between them: each step between them is an
    /// `await` in that task. Thus a `@TaskLocal` value that the host sets
    /// around its own call of ``RouterSessionDirectory/fork(_:)`` is visible
    /// in this call, and a fork call of another caller does not see it, also
    /// when the two forks run at the same time on one source for one client.
    /// A host can use such a value to find its own data for the fork.
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
    /// The request is usable only in this call. When the call returns or
    /// throws, the directory closes the request: a later build throws
    /// ``SessionLaunchForkError/requestClosed(_:)``, and a build that is in
    /// flight at the close discards its fork.
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

    /// Gives the model and the configuration that
    /// ``RouterSessionDirectory/importSession(_:transcript:)`` writes an
    /// imported session with (D209 (h)).
    ///
    /// The launcher resolves the agent of `request` as it does for a start:
    /// with no `agentID`, the agent is the `AGENT.md` of the folder, else the
    /// default agent (D71). It gives the model handle of the default of that
    /// agent, as the session of a start of that agent gets it, and the
    /// configuration of that agent: its instructions, its recording root,
    /// its compaction settings and its resolved ``SessionConfiguration/agentID``
    /// and ``SessionConfiguration/agentName``.
    ///
    /// The directory then sets the facts of the import on the configuration:
    /// the folder of the request, the name, `startedBy`, the origin
    /// `import` and the provenance. It writes the recording with
    /// ``RoutedModel/recordSession(from:configuration:)``. No session is
    /// live: the launcher makes no session, and the host restores the
    /// imported session with ``restoreSession(id:)`` when a client opens it.
    ///
    /// A launcher that does not implement this operation gets the default
    /// of this protocol, which throws `SessionDirectoryError.importUnsupported`.
    ///
    /// - Parameter request: The import request, exactly as the directory got
    ///   it: a nil agent stays nil.
    /// - Returns: The model and the configuration of the import.
    /// - Throws: `SessionDirectoryError.unknownAgent(_:nearNames:)` when the
    ///   agent id names no agent, `SessionDirectoryError.notADirectory(_:)`
    ///   when the folder is not a folder, or the error of the host.
    func importTarget(for request: SessionImportRequest) async throws -> SessionImportTarget
}

/// The model and the configuration that an imported session is written with
/// (D209 (h)): what ``SessionLauncher/importTarget(for:)`` gives
/// ``RouterSessionDirectory/importSession(_:transcript:)``.
public struct SessionImportTarget: Sendable {
    /// The model handle of the default of the agent of the import. The
    /// directory writes the recording through it, so the record holds its
    /// slot, its model and the resolved profile of its run.
    public var model: RoutedLLM

    /// The configuration of the agent of the import. The directory sets the
    /// facts of the import on it before the write.
    public var configuration: SessionConfiguration

    /// Makes the model and the configuration of an import.
    ///
    /// - Parameters:
    ///   - model: The model handle of the default of the agent.
    ///   - configuration: The configuration of the agent.
    public init(model: RoutedLLM, configuration: SessionConfiguration) {
        self.model = model
        self.configuration = configuration
    }
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

    /// See ``SessionLauncher/importTarget(for:)``. The default gives no
    /// model: the launcher cannot import.
    ///
    /// - Parameter request: The import request of the directory.
    /// - Returns: Nothing.
    /// - Throws: `SessionDirectoryError.importUnsupported`.
    public func importTarget(for request: SessionImportRequest) async throws -> SessionImportTarget {
        throw SessionDirectoryError.importUnsupported
    }
}
