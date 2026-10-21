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
/// with no `await`, so the synchronous
/// ``register(_:kind:parentID:requestedByClient:)`` can build one too.
///
/// The directory starts a root session through the ``SessionLauncher`` that
/// the host gives with ``useLauncher(_:)`` (ROUTER-8), because Router cannot
/// compose the tools of a session and does not know the agent catalog.
/// ``shutdown()`` releases the launcher again.
///
/// This version answers ``sessions(matching:)`` and ``summary(of:)`` for the
/// live sessions, ``start(_:)`` starts a root session through the launcher,
/// and ``events()`` gives `started` for each session it registers. The other
/// requirements of the port have provisional bodies that later cards
/// replace: the tag and title changes (ROUTER-3), ``send(_:)``,
/// ``inbox(of:markRead:)`` and ``message(_:to:)`` (ROUTER-4), and
/// ``archive(_:by:)`` (ROUTER-11).
public actor RouterSessionDirectory: SessionDirectory {
    /// The agent id of a session that recorded none, for example a session
    /// from before ROUTER-1: the default agent, the D71 fallback when neither
    /// the start nor the folder's `AGENT.md` names one. Confirmed by the owner
    /// of session.md.
    static let defaultAgentID = "default"

    /// The origin of a session that recorded none. A session from before
    /// `facts.json` was opened by an ACP `session/new`, so its origin is the
    /// client. Confirmed by the owner of session.md.
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

    /// What the directory keeps under its one lock: the live registry and
    /// the open event streams. One lock keeps both, so an event that a change
    /// of the registry sends reaches each stream in the order of the changes.
    struct Registry {
        /// The live registry, keyed by session id.
        var entries: [ULID: Entry] = [:]

        /// The open streams of ``RouterSessionDirectory/events()``.
        var fanout = SessionDirectoryEventFanout()
    }

    /// The registry and the event streams. A lock keeps them, so the
    /// synchronous ``register(_:kind:parentID:requestedByClient:)`` and
    /// ``unregister(_:)`` need no `await`.
    private let state = Mutex<Registry>(Registry())

    /// The launcher that ``start(_:)`` starts each root session through, or
    /// `nil` before ``useLauncher(_:)`` and after ``shutdown()``. A directory
    /// with no launcher throws `noLauncher` from ``start(_:)``.
    private var launcher: (any SessionLauncher)?

    /// Makes an empty directory.
    public init() {}

    // MARK: - Registry

    /// Adds a live session to the directory. The directory holds it weakly.
    ///
    /// Under the lock that adds the entry, each open stream of ``events()``
    /// gets `started` with the summary of the session, so `started` is the
    /// first event of the session on each stream. A second registration of a
    /// session that is still live replaces its entry and sends no second
    /// `started`.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - kind: The kind of the session.
    ///   - parentID: The parent of a subagent, or the original session of a
    ///     fork; `nil` for a root session.
    ///   - requestedByClient: The UI client that asked for the start, for the
    ///     tab rule (``SessionConfiguration/requestedByClient``); `nil` when
    ///     no client asked.
    nonisolated func register(
        _ session: any RoutedSession, kind: SessionKind, parentID: ULID?, requestedByClient: String? = nil
    ) {
        let entry = Entry(session: session, kind: kind, parentID: parentID, updatedAt: session.id.timestamp)
        state.withLock { registry in
            let isAlreadyLive = registry.entries[session.id]?.session != nil
            registry.entries[session.id] = entry
            guard !isAlreadyLive else { return }
            registry.fanout.send(.started(Self.summary(of: session, in: entry), requestedByClient: requestedByClient))
        }
    }

    /// Takes a session off the live list. An id the directory does not hold
    /// changes nothing.
    ///
    /// - Parameter id: The session id.
    nonisolated func unregister(_ id: ULID) {
        state.withLock { _ = $0.entries.removeValue(forKey: id) }
    }

    /// The summaries of every live session, in no order. An entry whose
    /// session is gone is dropped from the registry here.
    ///
    /// - Returns: One summary for each live session.
    private nonisolated func liveSummaries() -> [SessionSummary] {
        state.withLock { registry in
            registry.entries = registry.entries.filter { $0.value.session != nil }
            return registry.entries.values.compactMap(Self.summary(of:))
        }
    }

    /// The summary of one registered session, or `nil` when the session is
    /// gone.
    ///
    /// - Parameter entry: The registry entry.
    /// - Returns: The summary.
    private static func summary(of entry: Entry) -> SessionSummary? {
        entry.session.map { summary(of: $0, in: entry) }
    }

    /// The summary of a live session, from its `nonisolated` properties, its
    /// facts and its registry entry, with no `await`.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - entry: The registry entry of `session`.
    /// - Returns: The summary.
    private static func summary(of session: any RoutedSession, in entry: Entry) -> SessionSummary {
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
        state.withLock { registry in
            registry.entries[id].flatMap(Self.summary(of:))
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

    // MARK: - Launcher

    /// Gives the directory the launcher of the host (ROUTER-8).
    /// ``start(_:)`` starts each root session through it. A later call
    /// replaces the launcher, and ``shutdown()`` releases it.
    ///
    /// - Parameter launcher: The launcher of the host.
    public func useLauncher(_ launcher: any SessionLauncher) {
        self.launcher = launcher
    }

    /// Releases the launcher and ends each open stream of ``events()``.
    ///
    /// The directory holds the launcher, and the launcher makes surfaces that
    /// hold the directory, so the host calls this at shutdown to break that
    /// loop. After the call, ``start(_:)`` throws `noLauncher` until the next
    /// ``useLauncher(_:)``. The streams end after the lock is released,
    /// because the end of a stream takes the lock to leave the directory.
    public func shutdown() {
        launcher = nil
        let openStreams = state.withLock { $0.fanout.removeAll() }
        for continuation in openStreams {
            continuation.finish()
        }
    }

    /// See `SessionDirectory.start(_:)`. Starts a new root session through
    /// the launcher, then delivers the first message of `request`, which
    /// starts the first turn of the session.
    ///
    /// The launcher gets `request` as it came: a nil agent and a nil folder
    /// stay nil, and the launcher resolves them. The session it returns
    /// registered itself when ``RoutedModel/makeSession(configuration:)``
    /// vended it, and that registration sent the one `started` of the
    /// session, so `start` sends no second `started`. A session that lacks a
    /// fact of the request gets it here (``admit(session:startedFor:)``).
    ///
    /// The first message is ``MailBody/agentMessage(from:content:)`` from
    /// the session `startedBy`, with the sender ``MailSender/session(_:)``,
    /// when the request names one, else a user message with the sender
    /// ``MailSender/user``. It waits in the mail queue of the session.
    ///
    /// - Parameter request: The agent, the working folder, the first message
    ///   and the facts of the session.
    /// - Returns: The summary of the new session.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, the error of the launcher, the error of a write of the
    ///   facts of the session, the refusal of the first message, or
    ///   `SessionDirectoryError.unknownSession` when the session closed
    ///   before `start` returns.
    public func start(_ request: SessionStartRequest) async throws -> SessionSummary {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        let session = try await launcher.launchRootSession(request)
        try admit(session: session, startedFor: request)
        _ = try session.mail(Self.firstMail(of: request))
        guard let summary = try await summary(of: session.id) else {
            throw SessionDirectoryError.unknownSession(session.id)
        }
        return summary
    }

    /// Makes the session that the launcher returned for `request` live in
    /// the directory with each fact of `request`.
    ///
    /// A session from this router registered itself, and its `started` went
    /// out. When it lacks a fact of `request` (its launcher broke the
    /// launcher contract), this writes the fact and sends `factsChanged`. A
    /// session from another router is not in the directory: this writes the
    /// missing facts first and then registers it as a root, so its one
    /// `started` holds them and the client of `request`.
    ///
    /// - Parameters:
    ///   - session: The session that the launcher returned.
    ///   - request: The start request of the session.
    /// - Throws: The error of a write of `facts.json`.
    private func admit(session: any RoutedSession, startedFor request: SessionStartRequest) throws {
        guard isRegistered(session: session) else {
            try Self.writeMissingFacts(of: request, to: session)
            register(session, kind: .root, parentID: nil, requestedByClient: request.requestedByClient)
            return
        }
        if try Self.writeMissingFacts(of: request, to: session) {
            recordFactsChange(of: session.id)
        }
    }

    /// Tells whether the directory holds `session` itself as a live entry.
    ///
    /// - Parameter session: A session.
    /// - Returns: `true` when the live entry of its id is `session`.
    private nonisolated func isRegistered(session: any RoutedSession) -> Bool {
        state.withLock { $0.entries[session.id]?.session === session }
    }

    /// Sets the time of the last change of the session `id` to now, and
    /// gives `factsChanged` with its new summary to each open stream, under
    /// the lock of the registry. An id with no live session changes nothing.
    ///
    /// - Parameter id: The session id.
    private nonisolated func recordFactsChange(of id: ULID) {
        state.withLock { registry in
            guard var entry = registry.entries[id], let session = entry.session else { return }
            entry.updatedAt = Date()
            registry.entries[id] = entry
            registry.fanout.send(.factsChanged(Self.summary(of: session, in: entry)))
        }
    }

    /// Writes each fact of `request` that `session` lacks to the facts of
    /// `session` (``complete(facts:with:)``).
    ///
    /// Only a ``RoutedSessionActor`` can change its facts. Each session that
    /// a router vends is one, so another session that lacks a fact is a
    /// surprise: the call stops a debug build, logs the surprise, and leaves
    /// the facts as the session holds them.
    ///
    /// - Parameters:
    ///   - request: The start request of the session.
    ///   - session: The session that the launcher returned.
    /// - Returns: `true` when the call changed the facts of `session`.
    /// - Throws: The error of the write of `facts.json`.
    @discardableResult
    private static func writeMissingFacts(
        of request: SessionStartRequest, to session: any RoutedSession
    ) throws -> Bool {
        var completed = session.facts
        complete(facts: &completed, with: request)
        guard completed != session.facts else { return false }
        guard let actor = session as? RoutedSessionActor else {
            assertionFailure("a launcher returned a session that lacks the facts of its request and cannot change them")
            RouterTelemetry.makeLogger(.sessionDirectory).error(
                "a launcher returned a session that lacks the facts of its request and cannot change them; the facts stay as the session holds them",
                metadata: [RouterTelemetry.LogMetadataKey.sessionId: "\(session.id)"])
            return false
        }
        try actor.updateFacts { complete(facts: &$0, with: request) }
        return true
    }

    /// Adds each fact of `request` that `facts` lacks: the tags of the
    /// request join the tags, and the title, `startedBy` and the origin of
    /// the request fill a fact that is `nil`. A fact that `facts` holds
    /// stays.
    ///
    /// - Parameters:
    ///   - facts: The facts of a session.
    ///   - request: The start request of the session.
    private static func complete(facts: inout SessionFacts, with request: SessionStartRequest) {
        facts.tags.formUnion(request.tags)
        facts.title = facts.title ?? request.title
        facts.startedBy = facts.startedBy ?? request.startedBy
        facts.origin = facts.origin ?? request.origin
    }

    /// The mail that carries the first message of `request`.
    ///
    /// - Parameter request: The start request.
    /// - Returns: An agent message from `startedBy` when the request names
    ///   it, else a user message.
    private static func firstMail(of request: SessionStartRequest) -> Mail {
        guard let startedBy = request.startedBy else {
            return Mail(sender: .user, body: .userMessage(prompt: request.firstMessage, options: UserMessageOptions()))
        }
        return Mail(sender: .session(startedBy), body: .agentMessage(from: startedBy, content: request.firstMessage))
    }

    // MARK: - Provisional bodies

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

    /// See `SessionDirectory.message(_:to:)`. Provisional until ROUTER-4: no
    /// message was delivered yet, so every lookup gives `nil`. It never throws
    /// `unknownSession`, unlike ``inbox(of:markRead:)``, and marks nothing read.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - recipient: The session id that the message went to.
    /// - Returns: `nil`.
    public func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage? {
        nil
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

    // MARK: - Events

    /// See `SessionDirectory.events()`. Each call makes a new stream with the
    /// `.bufferingNewest(256)` policy; it gets each event after the call, and
    /// a slow reader loses old events, not new ones. Each session registered
    /// after the call gives `started` first, and the events of one session
    /// come in order. A stream that ends leaves the directory.
    ///
    /// An event carries no sequence number and no cursor. The `sessions`
    /// graph of FoundationModelsMultitool wraps each event it reads from this
    /// stream in the change log of the Extras GraphQL toolkit (EXTRAS-10),
    /// which gives the cursor (epoch and sequence) and the time of each
    /// entry. Router keeps no change log and links no GraphQL (D74, D106).
    ///
    /// An event holds no message text longer than the message length limit
    /// (ROUTER-5, rule 5 of session.md section 7). The message cards enforce
    /// the limit before a message reaches an event.
    ///
    /// - Returns: A stream of the changes in the directory.
    public nonisolated func events() -> AsyncStream<SessionDirectoryEvent> {
        let (stream, continuation) = SessionDirectoryEventFanout.makeStream()
        let streamID = state.withLock { $0.fanout.add(continuation) }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { $0.fanout.remove(streamID) }
        }
        return stream
    }

    /// Gives `event` to each open stream of ``events()``, under the lock of
    /// the registry. The later directory cards send `factsChanged`,
    /// `stateChanged`, `messageDelivered` and `archived` through it.
    ///
    /// - Parameter event: The event.
    nonisolated func emit(_ event: SessionDirectoryEvent) {
        state.withLock { $0.fanout.send(event) }
    }

    /// The number of open streams of ``events()``. A stream that ends leaves
    /// the count.
    nonisolated var openEventStreamCount: Int {
        state.withLock { $0.fanout.count }
    }
}
