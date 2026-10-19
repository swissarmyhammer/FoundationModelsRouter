import Foundation
import FoundationModelsHooks
import Synchronization

/// The session that a new session comes from, as the hook lineage reads it.
///
/// A session with no parent (a new root session, or a restored root session)
/// has no value of this type.
enum HookParent: Sendable, Equatable {
    /// The session that started the new session as a sub-agent: the session
    /// of the parent call (``SessionConfiguration/parentCall``), or the
    /// recorded spawn parent (``SessionSidecar/AgentSpawn/parentSessionId``).
    case subagent(sessionID: String, sessionKey: String)

    /// The session that the new session is a fork of, with the working
    /// directory of that session.
    case fork(sessionID: String, sessionKey: String, workingDirectory: URL)

    /// The id of the parent session.
    var sessionID: String {
        switch self {
        case .subagent(let sessionID, _), .fork(let sessionID, _, _):
            sessionID
        }
    }
}

/// The hook identity of one session: its `HookSession` and the origin of its
/// `SessionStart`.
///
/// ``make(sessionID:workingDirectory:dataDirectory:parent:requestedKey:requestedOrigin:isRestored:)``
/// is the one function that holds the lineage rules.
struct HookLineage: Sendable, Equatable {
    /// The hook session of the session.
    let session: HookSession

    /// How the session started.
    let origin: SessionOrigin

    /// Applies the lineage rules to one session.
    ///
    /// - The key is `requestedKey` when the host gives one. Else a sub-agent
    ///   gets the key of its parent. A fork gets the key of its parent only
    ///   when its working directory is the working directory of its parent,
    ///   so that one key never holds two work trees. Each other session gets
    ///   its own id.
    /// - The origin is `requestedOrigin` when the host gives one. Else a
    ///   restored session is `.resumed`, a sub-agent is `.subagent`, a fork is
    ///   `.forked`, and each other session is `.new`.
    /// - The parent session id is the id of `parent`, or `nil`.
    ///
    /// - Parameters:
    ///   - sessionID: The id of the session.
    ///   - workingDirectory: The working directory of the session.
    ///   - dataDirectory: The data directory of the dispatcher.
    ///   - parent: The session that the session comes from, or `nil`.
    ///   - requestedKey: The key that the host gives
    ///     (``SessionConfiguration/hookSessionKey``), or `nil`.
    ///   - requestedOrigin: The origin that the host gives
    ///     (``SessionConfiguration/hookOrigin``), or `nil`.
    ///   - isRestored: Whether a restore makes the session from a recording.
    /// - Returns: The hook session and the origin of the session.
    static func make(
        sessionID: ULID,
        workingDirectory: URL,
        dataDirectory: URL,
        parent: HookParent?,
        requestedKey: String?,
        requestedOrigin: SessionOrigin?,
        isRestored: Bool
    ) -> HookLineage {
        let ownKey = sessionID.description
        let session = HookSession(
            sessionID: ownKey,
            sessionKey: requestedKey ?? derivedKey(ownKey: ownKey, workingDirectory: workingDirectory, parent: parent),
            parentSessionID: parent?.sessionID,
            workingDirectory: workingDirectory,
            dataDirectory: dataDirectory)
        let origin = requestedOrigin ?? (isRestored ? .resumed : derivedOrigin(of: parent))
        return HookLineage(session: session, origin: origin)
    }

    /// The key that the lineage gives a session when the host gives none.
    ///
    /// - Parameters:
    ///   - ownKey: The id of the session, as text.
    ///   - workingDirectory: The working directory of the session.
    ///   - parent: The session that the session comes from, or `nil`.
    /// - Returns: The key of the parent, or `ownKey`.
    private static func derivedKey(ownKey: String, workingDirectory: URL, parent: HookParent?) -> String {
        switch parent {
        case nil:
            ownKey
        case .subagent(_, let parentKey):
            parentKey
        case .fork(_, let parentKey, let parentDirectory):
            isSameDirectory(workingDirectory, parentDirectory) ? parentKey : ownKey
        }
    }

    /// The origin that the lineage gives a session that a restore did not
    /// make, when the host gives none.
    ///
    /// - Parameter parent: The session that the session comes from, or `nil`.
    /// - Returns: `.new`, `.subagent` or `.forked`.
    private static func derivedOrigin(of parent: HookParent?) -> SessionOrigin {
        switch parent {
        case nil: .new
        case .subagent: .subagent
        case .fork: .forked
        }
    }

    /// Tells if two directory URLs name the same directory.
    ///
    /// The comparison reads the standardized path with the symbolic links
    /// resolved, so `/a/b/../c`, `/a/c/` and `/a/c` are the same directory.
    ///
    /// - Parameters:
    ///   - directory: One directory.
    ///   - other: The other directory.
    /// - Returns: `true` when the two URLs name the same directory.
    private static func isSameDirectory(_ directory: URL, _ other: URL) -> Bool {
        comparablePath(of: directory) == comparablePath(of: other)
    }

    /// The path of a directory URL in the form that
    /// ``isSameDirectory(_:_:)`` compares.
    ///
    /// - Parameter directory: The directory.
    /// - Returns: The standardized path with the symbolic links resolved.
    private static func comparablePath(of directory: URL) -> String {
        directory.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The hooks of one router: its `HookDispatcher`, and the hook session of
/// each open session of the router.
///
/// The router gives one value to each ``RoutedModel`` that it resolves, so
/// each session on each slot reaches the same dispatcher. A sub-agent knows
/// only the id of its parent session (``SessionConfiguration/parentCall``),
/// so the router keeps the hook session of each open session to give the
/// sub-agent the key of its parent.
///
/// The type is `package` because the `package` initializer of
/// ``RoutedModel`` names it. Its members stay `internal`.
package final class RouterHooks: Sendable {
    /// The dispatcher that the hook events of each session go to.
    let dispatcher: HookDispatcher

    /// The hook session of each open session, by the id of the session as
    /// text.
    private let openSessions = Mutex<[String: HookSession]>([:])

    /// Makes the hooks of a router.
    ///
    /// - Parameter dispatcher: The dispatcher of the router.
    init(dispatcher: HookDispatcher) {
        self.dispatcher = dispatcher
    }

    /// The parent of a sub-agent whose parent session has the id `parentID`.
    ///
    /// The key is the key of the parent while the parent is open. A parent
    /// that is not open in this router (for example a parent of a restored
    /// sub-agent) gives its id as its key, which is the key of a root session.
    ///
    /// - Parameter parentID: The id of the parent session.
    /// - Returns: The sub-agent parent.
    func subagentParent(of parentID: ULID) -> HookParent {
        let sessionID = parentID.description
        let sessionKey = openSessions.withLock { $0[sessionID]?.sessionKey } ?? sessionID
        return .subagent(sessionID: sessionID, sessionKey: sessionKey)
    }

    /// Makes the hooks of one session, with the lineage rules of
    /// ``HookLineage``. The data directory is the data directory of
    /// ``dispatcher``.
    ///
    /// - Parameters:
    ///   - sessionID: The id of the session.
    ///   - workingDirectory: The working directory of the session.
    ///   - parent: The session that the session comes from, or `nil`.
    ///   - requestedKey: The key that the host gives, or `nil`.
    ///   - requestedOrigin: The origin that the host gives, or `nil`.
    ///   - isRestored: Whether a restore makes the session from a recording.
    /// - Returns: The hooks of the session. They send nothing until
    ///   ``SessionHooks/start()``.
    func makeSessionHooks(
        sessionID: ULID,
        workingDirectory: URL,
        parent: HookParent?,
        requestedKey: String? = nil,
        requestedOrigin: SessionOrigin? = nil,
        isRestored: Bool
    ) -> SessionHooks {
        SessionHooks(
            routerHooks: self,
            lineage: HookLineage.make(
                sessionID: sessionID, workingDirectory: workingDirectory,
                dataDirectory: dispatcher.dataDirectory, parent: parent, requestedKey: requestedKey,
                requestedOrigin: requestedOrigin, isRestored: isRestored))
    }

    /// Records an open session, so that a sub-agent of it finds its key.
    ///
    /// - Parameter session: The hook session of the open session.
    fileprivate func didOpen(_ session: HookSession) {
        openSessions.withLock { $0[session.sessionID] = session }
    }

    /// Forgets a session that ended.
    ///
    /// - Parameter session: The hook session of the session that ended.
    fileprivate func didClose(_ session: HookSession) {
        openSessions.withLock { $0[session.sessionID] = nil }
    }
}

/// The hooks of one session: its hook lineage, and the once-only
/// `SessionStart` and `SessionEnd` of the session.
///
/// The session factory calls ``start()`` when it made the session, and the
/// close of the session calls ``end()``. When the dispatcher has no visitor
/// at the start, the session sends no `SessionStart`, and then it also sends
/// no `SessionEnd`, so the dispatcher never gets an end of a session that it
/// did not see start. A session that is released with no close sends its
/// `SessionEnd` when the hooks are released, so the dispatcher does not keep
/// a queue for a session that no longer exists.
final class SessionHooks: Sendable {
    /// Where the session is in its hook life.
    private enum Phase {
        /// Made, with no `SessionStart` yet.
        case made
        /// Started. `postedStart` tells if the `SessionStart` went to the
        /// dispatcher.
        case open(postedStart: Bool)
        /// Ended. Nothing more goes to the dispatcher.
        case ended
    }

    /// The hooks of the router of the session.
    let routerHooks: RouterHooks

    /// The hook lineage of the session.
    let lineage: HookLineage

    /// The prompt hook state of the session: the screening mail, and the
    /// mail that waits for its `PostPrompt`.
    let prompts = PromptHookLedger()

    /// The phase of the session. The lock also keeps the order of the
    /// `SessionStart` and the `SessionEnd` posts.
    private let phase = Mutex(Phase.made)

    /// Makes the hooks of one session.
    ///
    /// - Parameters:
    ///   - routerHooks: The hooks of the router of the session.
    ///   - lineage: The hook lineage of the session.
    fileprivate init(routerHooks: RouterHooks, lineage: HookLineage) {
        self.routerHooks = routerHooks
        self.lineage = lineage
    }

    /// Sends the `SessionEnd` of a session that was released with no close.
    deinit {
        end()
    }

    /// The hook session of the session.
    var session: HookSession {
        lineage.session
    }

    /// The parent that a fork of this session has.
    var forkParent: HookParent {
        .fork(sessionID: session.sessionID, sessionKey: session.sessionKey, workingDirectory: session.workingDirectory)
    }

    /// Makes the hooks of a fork of this session.
    ///
    /// - Parameters:
    ///   - sessionID: The id of the fork.
    ///   - workingDirectory: The working directory of the fork.
    /// - Returns: The hooks of the fork.
    func makeForkHooks(sessionID: ULID, workingDirectory: URL) -> SessionHooks {
        routerHooks.makeSessionHooks(
            sessionID: sessionID, workingDirectory: workingDirectory, parent: forkParent, isRestored: false)
    }

    /// Records the session as open, and sends its `SessionStart` when the
    /// dispatcher has a visitor. A second call does nothing.
    func start() {
        phase.withLock { phase in
            guard case .made = phase else { return }
            let postsStart = !routerHooks.dispatcher.isEmpty
            phase = .open(postedStart: postsStart)
            routerHooks.didOpen(session)
            if postsStart {
                routerHooks.dispatcher.post(SessionStart(origin: lineage.origin), session: session)
            }
        }
    }

    /// Sends the `SessionEnd` of the session when its `SessionStart` went
    /// out, and forgets the session. Only the first call does this.
    func end() {
        phase.withLock { phase in
            if case .open(let postedStart) = phase {
                routerHooks.didClose(session)
                if postedStart {
                    routerHooks.dispatcher.post(SessionEnd(), session: session)
                }
            }
            phase = .ended
        }
    }
}
