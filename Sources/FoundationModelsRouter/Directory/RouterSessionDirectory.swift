import Foundation
import FoundationModelsExtras
import Synchronization

/// The session directory of one ``Router``: the Router side of the Extras
/// `SessionDirectory` port (ROUTER-3). The `sessions` tool, the `sessions`
/// graph and the trigger handler find, start, tag and message sessions
/// through it. ``Router/sessionDirectory`` holds one for each router.
///
/// The directory keeps a live registry of the sessions of the router. It
/// holds each session weakly, so it never keeps a session alive: a session
/// whose last strong reference is gone leaves every query. A summary is built
/// from the session's `nonisolated` properties and its ``RoutedSession/facts``
/// with no `await`, so the synchronous ``register(_:kind:parentID:)`` can build
/// one too.
///
/// This version answers ``sessions(matching:)`` and ``summary(of:)`` for the
/// live sessions. The other requirements of the port have provisional bodies
/// that later cards replace: ``start(_:)`` (ROUTER-8), the tag and title
/// changes and ``events()`` (ROUTER-3), ``send(_:)`` and ``inbox(of:markRead:)``
/// (ROUTER-4), and ``archive(_:by:)`` (ROUTER-11).
public actor RouterSessionDirectory: SessionDirectory {
    /// The agent id of a session that recorded none, for example a session
    /// from before ROUTER-1: the root agent (D71).
    static let defaultAgentID = "default"

    /// The origin of a session that recorded none.
    static let defaultOrigin: FoundationModelsExtras.SessionDirectoryOrigin = .client

    /// The reason of the one refused receipt ``send(_:)`` gives until the
    /// directory delivers messages (ROUTER-4).
    static let messagesUnavailableReason = "messages are not available yet"

    /// One registered session: a weak hold on it, and the facts of the
    /// directory that the session does not hold.
    struct Entry: Sendable {
        /// The session, or `nil` once its last strong reference is gone.
        weak var session: (any RoutedSession)?

        /// The kind of the session.
        let kind: SessionKind

        /// Subagent: the parent session. Fork: the original session. `nil`
        /// for a root session.
        let parentID: ULID?

        /// The time of the last change of the facts or the state of the
        /// session that the directory made. It starts at the time of the
        /// session's ULID.
        var updatedAt: Date
    }

    /// The live registry, keyed by session id. A lock keeps it, so the
    /// synchronous ``register(_:kind:parentID:)`` and ``unregister(_:)`` need
    /// no `await`.
    private let live = Mutex<[ULID: Entry]>([:])

    /// Makes an empty directory.
    public init() {}

    // MARK: - Registry

    /// Adds a live session to the directory. The directory holds it weakly.
    /// A second registration of the same id replaces the first.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - kind: The kind of the session.
    ///   - parentID: The parent of a subagent, or the original session of a
    ///     fork; `nil` for a root session.
    nonisolated func register(_ session: any RoutedSession, kind: SessionKind, parentID: ULID?) {
        let entry = Entry(session: session, kind: kind, parentID: parentID, updatedAt: session.id.timestamp)
        live.withLock { $0[session.id] = entry }
    }

    /// Takes a session off the live list. An id the directory does not hold
    /// changes nothing.
    ///
    /// - Parameter id: The session id.
    nonisolated func unregister(_ id: ULID) {
        live.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// The summaries of every live session, in no order. An entry whose
    /// session is gone is dropped from the registry here.
    ///
    /// - Returns: One summary for each live session.
    private nonisolated func liveSummaries() -> [SessionSummary] {
        live.withLock { entries in
            entries = entries.filter { $0.value.session != nil }
            return entries.values.compactMap(Self.summary(of:))
        }
    }

    /// The summary of one registered session, or `nil` when the session is
    /// gone.
    ///
    /// - Parameter entry: The registry entry.
    /// - Returns: The summary.
    private static func summary(of entry: Entry) -> SessionSummary? {
        guard let session = entry.session else { return nil }
        let facts = session.facts
        return SessionSummary(
            id: session.id,
            agentID: facts.agentID ?? defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: session.workingDirectory,
            title: facts.title,
            tags: facts.tags,
            kind: entry.kind,
            // Until the directory follows the work state (ROUTER-9), a live
            // session is idle.
            state: .idle,
            parentID: entry.parentID,
            startedBy: facts.startedBy,
            origin: facts.origin ?? defaultOrigin,
            createdAt: session.id.timestamp,
            updatedAt: entry.updatedAt,
            isLive: true)
    }

    // MARK: - Query

    /// See `SessionDirectory.sessions(matching:)`. Only the live sessions
    /// answer, newest first (ULID order), cut to the limit of `query`.
    ///
    /// - Parameter query: The filter. Each field that is not nil must match.
    /// - Returns: The summaries of the matching live sessions.
    public func sessions(matching query: SessionQuery) async throws -> [SessionSummary] {
        let folder = query.workingDirectory.map(Self.comparablePath(of:))
        let matching = liveSummaries()
            .filter { summary in
                folder.map { $0 == Self.comparablePath(of: summary.workingDirectory) } ?? true
            }
            .filter { Self.matches($0, query) }
            .sorted { $0.id > $1.id }
        return Array(matching.prefix(max(0, query.limit)))
    }

    /// See `SessionDirectory.summary(of:)`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary, or `nil` when no live session has this id.
    public func summary(of id: ULID) async throws -> SessionSummary? {
        live.withLock { entries in
            entries[id].flatMap(Self.summary(of:))
        }
    }

    /// Tells whether `summary` matches each filter of `query` other than the
    /// working folder, which ``sessions(matching:)`` compares by path.
    ///
    /// - Parameters:
    ///   - summary: The summary of one live session.
    ///   - query: The filter.
    /// - Returns: `true` when each field of `query` that is not nil matches.
    private static func matches(_ summary: SessionSummary, _ query: SessionQuery) -> Bool {
        let checks: [Bool?] = [
            query.agentID.map { $0 == summary.agentID },
            query.tag.map { summary.tags.contains($0) },
            query.kind.map { $0 == summary.kind },
            query.state.map { $0 == summary.state },
            query.parentID.map { $0 == summary.parentID },
            query.startedBy.map { $0 == summary.startedBy },
        ]
        return checks.allSatisfy { $0 ?? true }
    }

    /// The path a folder compares by: symbolic links resolved, and no
    /// trailing `/`.
    ///
    /// - Parameter folder: A working folder.
    /// - Returns: The comparable path.
    static func comparablePath(of folder: URL) -> String {
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    // MARK: - Provisional bodies

    /// See `SessionDirectory.start(_:)`. Provisional: the directory has no
    /// launcher yet (ROUTER-8).
    ///
    /// - Parameter request: The start request.
    /// - Returns: Nothing yet.
    /// - Throws: `SessionDirectoryError.noLauncher`.
    public func start(_ request: SessionStartRequest) async throws -> SessionSummary {
        throw SessionDirectoryError.noLauncher
    }

    /// See `SessionDirectory.addTags(_:to:)`. Provisional until the tags card
    /// of ROUTER-3.
    ///
    /// - Parameters:
    ///   - tags: The tags to add.
    ///   - id: The session id.
    /// - Returns: Nothing yet.
    /// - Throws: `SessionDirectoryError.unknownSession`.
    public func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary {
        throw SessionDirectoryError.unknownSession(id)
    }

    /// See `SessionDirectory.removeTags(_:from:)`. Provisional until the tags
    /// card of ROUTER-3.
    ///
    /// - Parameters:
    ///   - tags: The tags to remove.
    ///   - id: The session id.
    /// - Returns: Nothing yet.
    /// - Throws: `SessionDirectoryError.unknownSession`.
    public func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary {
        throw SessionDirectoryError.unknownSession(id)
    }

    /// See `SessionDirectory.setTitle(_:of:)`. Provisional until the tags card
    /// of ROUTER-3.
    ///
    /// - Parameters:
    ///   - title: The new title.
    ///   - id: The session id.
    /// - Returns: Nothing yet.
    /// - Throws: `SessionDirectoryError.unknownSession`.
    public func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary {
        throw SessionDirectoryError.unknownSession(id)
    }

    /// See `SessionDirectory.send(_:)`. Provisional until ROUTER-4: one
    /// refused receipt.
    ///
    /// - Parameter message: The message.
    /// - Returns: One `refused` receipt with no target.
    public func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        [SessionSendReceipt(outcome: .refused, reason: Self.messagesUnavailableReason)]
    }

    /// See `SessionDirectory.inbox(of:markRead:)`. Provisional until
    /// ROUTER-4: no messages.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read.
    /// - Returns: No messages.
    public func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage] {
        []
    }

    /// See `SessionDirectory.archive(_:by:)`. Provisional until ROUTER-11.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it.
    /// - Returns: Nothing yet.
    /// - Throws: `SessionDirectoryError.unknownSession`.
    public func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary {
        throw SessionDirectoryError.unknownSession(id)
    }

    /// See `SessionDirectory.events()`. Provisional until the events card of
    /// ROUTER-3: a stream that is already finished.
    ///
    /// - Returns: A finished stream.
    public nonisolated func events() -> AsyncStream<SessionDirectoryEvent> {
        AsyncStream { $0.finish() }
    }
}
