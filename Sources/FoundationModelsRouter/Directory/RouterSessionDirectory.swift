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
/// the host gives with ``use(launcher:)`` (ROUTER-8), because Router cannot
/// compose the tools of a session and does not know the agent catalog.
/// ``shutdown()`` releases the launcher again.
///
/// For each registered session, one task reads the events of the session
/// and keeps its work state and its last summary (ROUTER-9,
/// ``SessionStateTracking``). The task holds neither the session nor the
/// directory, and it ends when the session closes or is released.
///
/// The directory also owns the record of past sessions (D72). Each new
/// durable root session appends its line to `sessions.jsonl` when it
/// registers, and the root sessions on disk under the recording roots of the
/// host (``useRecordingRoots(_:)``) answer as recorded summaries
/// (``RecordedSessions``).
///
/// This version answers ``sessions(matching:)`` and ``summary(of:)`` for the
/// live sessions, with the state and the last summary of each, and for the
/// recorded root sessions, ``start(_:)`` starts a root session through the
/// launcher, and ``events()`` gives `started` for each session it registers and
/// `stateChanged` for each change of what that event carries: the state, and
/// the last summary when the state is idle (`nil` with any other state, as
/// the port documents). ``summary(of:)`` reports the last summary in each
/// state. ``send(_:)`` delivers a message to each live target of its address
/// as a `Mail` by the delivery rules of ROUTER-5, restores a recorded target
/// through the launcher, or starts a session of an agent for it, keeps each
/// delivered message in the ledger of its target (``SessionMessageLedger``,
/// ROUTER-4), and sends `messageDelivered`; ``inbox(of:markRead:)`` and
/// ``message(_:to:)`` read that ledger, and a read mark withdraws the mail
/// that still waits. The other requirements of the port have provisional
/// bodies that later cards replace: the tag and title changes (ROUTER-3) and
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

    /// The reason of the refused receipt of a target that the resolver found
    /// live, and that left the directory or closed before its mail went out.
    static let notLiveReason = "not live"

    /// The chain depth of each message until ROUTER-5 computes it from the
    /// turn of the sender: the depth of a message from a user turn or from a
    /// UI.
    static let firstChainDepth = 1

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

        /// The work state and the last summary of the session (ROUTER-9).
        var tracking = SessionStateTracking()

        /// The task that reads the events of the session and follows its
        /// state (``followState(of:reading:)``), or `nil` before the
        /// registration starts it.
        var stateFeed: Task<Void, Never>?
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
    /// `nil` before ``use(launcher:)`` and after ``shutdown()``. A directory
    /// with no launcher throws `noLauncher` from ``start(_:)``.
    private var launcher: (any SessionLauncher)?

    /// The recording roots of the host, read at each query that includes
    /// the recorded sessions. A directory with none gives no recorded
    /// session.
    private var recordingRoots: @Sendable () async throws -> [URL] = { [] }

    /// The message ledger of each session that the directory delivered a
    /// message to or read the inbox of, by session id. A ledger is read from
    /// its recording directory at its first use and held here after, so the
    /// ledger of a memory-only session lives here alone.
    private var ledgers: [ULID: SessionMessageLedger] = [:]

    /// The restore through the launcher that runs now for each recorded
    /// session, by session id (``restore(_:through:)``). Two sends to one
    /// recorded session while its restore runs share that one restore, so
    /// the launcher never makes two live sessions with one id. A restore
    /// leaves the map when it ends.
    private var restores: [ULID: Task<any RoutedSession, any Error>] = [:]

    /// Makes an empty directory.
    public init() {}

    // MARK: - Registry

    /// Adds a live session to the directory. The directory holds it weakly.
    ///
    /// Under the lock that adds the entry, each open stream of ``events()``
    /// gets `started` with the summary of the session, so `started` is the
    /// first event of the session on each stream. The same lock starts the
    /// one task that follows the state of the session
    /// (``followState(of:reading:)``), so each `stateChanged` of the session
    /// comes after its `started`.
    ///
    /// A second registration of a session that is still live replaces its
    /// kind and its parent, and keeps its time of change, its state and its
    /// feed task. It sends no second `started`.
    ///
    /// The first registration of a root session appends its line to the
    /// record of past sessions (``RecordedSessions/appendIndexRecord(of:)``),
    /// after the lock is released.
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
        var entry = Entry(session: session, kind: kind, parentID: parentID, updatedAt: session.id.timestamp)
        let isFirstRegistration = state.withLock { registry in
            if let live = registry.entries[session.id], live.session != nil {
                entry.updatedAt = live.updatedAt
                entry.tracking = live.tracking
                entry.stateFeed = live.stateFeed
                registry.entries[session.id] = entry
                return false
            }
            registry.entries[session.id]?.stateFeed?.cancel()
            entry.stateFeed = followState(of: session, reading: Self.makeEventFeed(of: session))
            registry.entries[session.id] = entry
            registry.fanout.send(.started(Self.summary(of: session, in: entry), requestedByClient: requestedByClient))
            return true
        }
        guard isFirstRegistration, kind == .root else { return }
        RecordedSessions.appendIndexRecord(of: session)
    }

    /// Takes a session off the live list and ends the task that follows its
    /// state. An id the directory does not hold changes nothing.
    ///
    /// - Parameter id: The session id.
    nonisolated func unregister(_ id: ULID) {
        state.withLock { $0.entries.removeValue(forKey: id)?.stateFeed?.cancel() }
    }

    /// The summaries of every live session, in no order. An entry whose
    /// session is gone is dropped from the registry here, and the task that
    /// follows its state ends.
    ///
    /// - Returns: One summary for each live session.
    private nonisolated func liveSummaries() -> [SessionSummary] {
        state.withLock { registry in
            for gone in registry.entries.values where gone.session == nil {
                gone.stateFeed?.cancel()
            }
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
            state: entry.tracking.state,
            parentID: entry.parentID,
            startedBy: facts.startedBy,
            origin: facts.origin ?? defaultOrigin,
            createdAt: session.id.timestamp,
            updatedAt: entry.updatedAt,
            lastSummary: entry.tracking.lastSummary,
            isLive: true)
    }

    // MARK: - Query

    /// See `SessionDirectory.sessions(matching:)`. The live sessions answer,
    /// and with `includesRecorded` the root sessions on disk under the
    /// recording roots too (``RecordedSessions``); a session that is live and
    /// recorded answers once, as live. The result is newest first (ULID
    /// order), cut to the limit of `query`.
    ///
    /// - Parameter query: The filter. Each field that is not nil must match.
    /// - Returns: The summaries of the matching sessions.
    /// - Throws: The error of the recording roots of the host, or of a read
    ///   of the record of past sessions (``RecordedSessions/summaries()``).
    public func sessions(matching query: SessionQuery) async throws -> [SessionSummary] {
        let folder = query.workingDirectory.map(Self.comparablePath(of:))
        let live = liveSummaries()
        let candidates = query.includesRecorded ? Self.merging(live: live, recorded: try await recordedSummaries()) : live
        let matching = candidates
            .filter { summary in
                folder.map { $0 == Self.comparablePath(of: summary.workingDirectory) } ?? true
            }
            .filter { Self.matches($0, query) }
            .sorted { $0.id > $1.id }
        return Array(matching.prefix(max(0, query.limit)))
    }

    /// See `SessionDirectory.summary(of:)`. A live session answers with its
    /// live summary; a session that is not live answers with its recorded
    /// summary (``RecordedSessions``), as the Extras port reads recorded
    /// sessions with no `includesRecorded` flag here.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary, or `nil` when no live or recorded session has
    ///   this id.
    /// - Throws: The error of the recording roots of the host, or of a read
    ///   of the record of past sessions.
    public func summary(of id: ULID) async throws -> SessionSummary? {
        guard let live = liveSummary(of: id) else {
            return try await recordedSummaries().first { $0.id == id }
        }
        return live
    }

    /// The summary of the live session `id`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary, or `nil` when the directory holds no live
    ///   session with the id.
    private nonisolated func liveSummary(of id: ULID) -> SessionSummary? {
        state.withLock { registry in
            registry.entries[id].flatMap(Self.summary(of:))
        }
    }

    /// Tells whether `summary` matches each filter of `query` other than the
    /// working folder, which ``sessions(matching:)`` compares by path.
    ///
    /// - Parameters:
    ///   - summary: The summary of one live or recorded session.
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

    /// The summaries of the root sessions on disk under the recording roots
    /// of the host (``useRecordingRoots(_:)``).
    ///
    /// - Returns: One summary for each recorded root session, in no order.
    /// - Throws: The error of the recording roots of the host, or of a read
    ///   of the record of past sessions.
    private func recordedSummaries() async throws -> [SessionSummary] {
        try RecordedSessions(roots: try await recordingRoots()).summaries()
    }

    /// The live summaries, and each recorded summary whose session is not
    /// live: a live session wins over its own record.
    ///
    /// - Parameters:
    ///   - live: The summaries of the live sessions.
    ///   - recorded: The summaries of the recorded sessions.
    /// - Returns: One summary for each session, in no order.
    private static func merging(live: [SessionSummary], recorded: [SessionSummary]) -> [SessionSummary] {
        let liveIDs = Set(live.map(\.id))
        return live + recorded.filter { !liveIDs.contains($0.id) }
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

    // MARK: - Recording roots

    /// Gives the directory the recording roots of the host: the folders that
    /// hold a `sessions.jsonl` (``SessionIndex``) beside the recording
    /// directories of its root sessions. Router reads no setting of the host
    /// to find them. A query with `includesRecorded`, and ``summary(of:)``
    /// for an id with no live session, read the roots again each time, so a
    /// root the host adds later is found. A later call replaces the roots.
    ///
    /// - Parameter roots: Gives the recording roots of the host.
    public func useRecordingRoots(_ roots: @escaping @Sendable () async throws -> [URL]) {
        recordingRoots = roots
    }

    // MARK: - Launcher

    /// Gives the directory the launcher of the host (ROUTER-8).
    /// ``start(_:)`` starts each root session through it. A later call
    /// replaces the launcher, and ``shutdown()`` releases it.
    ///
    /// - Parameter launcher: The launcher of the host.
    public func use(launcher: any SessionLauncher) {
        self.launcher = launcher
    }

    /// Releases the launcher and ends each open stream of ``events()``.
    ///
    /// The directory holds the launcher, and the launcher makes surfaces that
    /// hold the directory, so the host calls this at shutdown to break that
    /// loop. After the call, ``start(_:)`` throws `noLauncher` until the next
    /// ``use(launcher:)``. The streams end after the lock is released,
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
        let session = try await launch(
            request, firstMail: mail(carrying: request.firstMessage, from: request.startedBy, inReplyTo: nil))
        guard let summary = try await summary(of: session.id) else {
            throw SessionDirectoryError.unknownSession(session.id)
        }
        return summary
    }

    /// Starts a new root session for `request` through the launcher, makes
    /// it live with the facts of `request`, and puts `firstMail` in its mail
    /// queue.
    ///
    /// - Parameters:
    ///   - request: The start request.
    ///   - firstMail: The mail that carries the first message of `request`.
    /// - Returns: The new session.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, the error of the launcher, the error of a write of the
    ///   facts of the session, or the refusal of the first mail.
    private func launch(_ request: SessionStartRequest, firstMail: Mail) async throws -> any RoutedSession {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        let session = try await launcher.launchRootSession(for: request)
        try admit(session: session, startedFor: request)
        _ = try session.mail(firstMail)
        return session
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

    /// The mail that carries a message, by the body rule of
    /// `SessionDirectory.send(_:)`: a message from a session is
    /// ``MailBody/agentMessage(from:content:)`` with the sender
    /// ``MailSender/session(_:)``, and a message from a user or a UI is a
    /// user message with the sender ``MailSender/user``, because a UI has no
    /// session id and the message is input of the user.
    ///
    /// The content of an agent message starts with the header of the sender
    /// (``AgentMessageHeader``): its agent, title and folder from its live
    /// summary, and `inReplyTo`. The renderer of the target cannot read the
    /// directory, so the header is how the model learns who sent the
    /// message (section 10.1 of `session.md`). A sender that is not live
    /// gets a header with its id and `inReplyTo` only. The directory writes
    /// the header first for each message, so a header that the sender writes
    /// in its text stays in the fenced text.
    ///
    /// - Parameters:
    ///   - id: The id of the mail. The default is a new id.
    ///   - text: The text of the message.
    ///   - sender: The session that sends the message, or `nil` for a user.
    ///   - inReplyTo: The id of the message that this message answers, or
    ///     `nil`.
    /// - Returns: The mail.
    private nonisolated func mail(
        id: MailID = MailID(), carrying text: String, from sender: ULID?, inReplyTo: MailID?
    ) -> Mail {
        guard let sender else {
            return Mail(id: id, sender: .user, body: .userMessage(prompt: text, options: UserMessageOptions()))
        }
        let header = AgentMessageHeader(sender: sender, summary: liveSummary(of: sender), inReplyTo: inReplyTo)
        let content = AgentMessageContent(header: header, text: text).encoded
        return Mail(id: id, sender: .session(sender), body: .agentMessage(from: sender, content: content))
    }

    // MARK: - Messages

    /// See `SessionDirectory.send(_:)`. Resolves the address
    /// (``FoundationModelsExtras/SessionAddress/resolution(from:among:recordedSummary:)``)
    /// and acts on the decision:
    ///
    /// - Each live target gets the message as a `Mail` in its own mail queue,
    ///   with the sender in its transcript (``deliver(_:to:)``). The receipt
    ///   follows the delivery rules of ROUTER-5: `delivered` for an idle
    ///   target, whose mail starts a turn, and `queued` for a working target
    ///   or one that needs input, whose mail waits in its queue for the end
    ///   of the turn. The session's pump then carries every waiting message
    ///   in one turn. No delivery waits for a free slot: the number of
    ///   sessions that work at the same time has no limit (D72).
    /// - A recorded target that is not live is restored through the
    ///   launcher, and then gets the message as a live target does
    ///   (``restoreThenDeliver(_:to:)``). A restore that throws is a
    ///   `refused` receipt with the text of the error.
    /// - An agent with no live root session gets a new one through the
    ///   launcher, with origin `message` and the message as its first
    ///   message, and the receipt is `started` (``startAgent(_:in:for:)``).
    /// - A refusal of the resolver is a `refused` receipt with its reason
    ///   and target. An archived target is one: it is never restored.
    ///
    /// Each delivered message goes into the ledger of its target
    /// (``SessionMessageLedger``) with the chain depth
    /// ``firstChainDepth``, and a `messageDelivered` event follows it.
    ///
    /// - Parameter message: The sender, the address, the text and the reply
    ///   id of the message.
    /// - Returns: One receipt for each target session.
    /// - Throws: `SessionDirectoryError.unknownSession` for a session sender
    ///   or a session id target that no live or recorded session has,
    ///   `SessionDirectoryError.noLauncher` when an agent address must start
    ///   a session or a recorded target must be restored with no launcher,
    ///   the start errors of the launcher for an agent address,
    ///   ``SessionMessageLedgerError/corruptLine(_:)`` when the
    ///   `messages.jsonl` of a target is damaged before its final line, the
    ///   file-system error of a read of a ledger, or the error of the
    ///   recording roots of the host.
    public func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        let recorded = try await recordedSummaries()
        let resolution = try message.to.resolution(from: message.from, among: liveSummaries()) { id in
            recorded.first { $0.id == id }
        }
        switch resolution {
        case .deliver(let targets):
            return try targets.map { try deliver(message, to: $0) }
        case .restoreThenDeliver(let id):
            let summary = try Self.recordedSummary(of: id, in: recorded)
            return [try await restoreThenDeliver(message, to: summary)]
        case .startAgent(let agentID, let folder):
            return [try await startAgent(agentID, in: folder, for: message)]
        case .refused(let reason, let target):
            return [SessionSendReceipt(target: target, outcome: .refused, reason: reason)]
        }
    }

    /// Delivers `message` to the live session `id`: puts its mail in the mail
    /// queue of the session, keeps it in the ledger of the session, and sends
    /// `messageDelivered`.
    ///
    /// The mail goes into the queue of the session in each state (the
    /// decision of the user on ROUTER-5), and the receipt tells which rule
    /// applied (``deliveryOutcome(of:)``): `delivered` when the session was
    /// idle, so the mail starts a turn, else `queued`, because the mail
    /// waits for the end of the turn that runs. A session that left the
    /// directory since the resolve, or that closed and takes no more mail,
    /// is refused as not live.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - id: The session id of a live target.
    /// - Returns: The `delivered` or `queued` receipt, or a `refused`
    ///   receipt as not live.
    /// - Throws: The error of a read of the ledger of the session, or a
    ///   refusal of the mail other than a closed session.
    private func deliver(_ message: OutgoingSessionMessage, to id: ULID) throws -> SessionSendReceipt {
        guard let session = liveSession(id), let outcome = deliveryOutcome(of: id) else {
            return SessionSendReceipt(target: id, outcome: .refused, reason: Self.notLiveReason)
        }
        let ledger = try ledger(of: id, in: Self.ledgerDirectory(of: session))
        let delivered = Self.delivered(message, to: id)
        do {
            _ = try session.mail(
                mail(
                    id: delivered.id, carrying: delivered.text, from: message.from.sessionID,
                    inReplyTo: delivered.inReplyTo))
        } catch MailRefusal.closed {
            return SessionSendReceipt(target: id, outcome: .refused, reason: Self.notLiveReason)
        }
        keep(delivered, in: ledger)
        return SessionSendReceipt(messageID: delivered.id, target: id, outcome: outcome)
    }

    /// The receipt outcome of a mail to the live session `id` now, by the
    /// work state that the directory tracks for it (ROUTER-9,
    /// ``SessionStateTracking``): `delivered` for `idle`, else `queued`.
    ///
    /// The tracking follows the events of the session in a task of its own,
    /// so it can lag behind the session by the events that task has not read
    /// yet. A mail that a send put in the queue of an idle session an
    /// instant ago can thus leave the state `idle` for a second send. The
    /// mail of that second send still waits in the queue for the end of the
    /// turn, as each mail does.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The outcome, or `nil` when the directory holds no entry for
    ///   `id`.
    private nonisolated func deliveryOutcome(of id: ULID) -> SessionSendReceipt.Outcome? {
        state.withLock { registry in
            registry.entries[id].map { $0.tracking.state == .idle ? .delivered : .queued }
        }
    }

    /// Restores the recorded session of `summary` through the launcher
    /// (ROUTER-8), makes it live in the directory, and delivers `message` to
    /// it (``deliver(_:to:)``), where its mail starts a turn.
    ///
    /// A session that this router restores registered itself when the
    /// restore vended it. A session from another router is not in the
    /// directory, so this registers it with the kind and the parent of its
    /// record.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - summary: The recorded summary of the target, which is not live.
    /// - Returns: The receipt of the delivery, or a `refused` receipt with
    ///   the text of the error when the restore throws.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, or the errors of ``deliver(_:to:)``.
    private func restoreThenDeliver(
        _ message: OutgoingSessionMessage, to summary: SessionSummary
    ) async throws -> SessionSendReceipt {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        let session: any RoutedSession
        do {
            session = try await restore(summary.id, through: launcher)
        } catch {
            return SessionSendReceipt(target: summary.id, outcome: .refused, reason: String(describing: error))
        }
        if !isRegistered(session: session) {
            register(session, kind: summary.kind, parentID: summary.parentID)
        }
        return try deliver(message, to: summary.id)
    }

    /// Restores the recorded session `id` through `launcher`, or joins the
    /// restore of `id` that runs now (``restores``).
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - launcher: The launcher of the directory.
    /// - Returns: The restored session.
    /// - Throws: The error of the restore.
    private func restore(_ id: ULID, through launcher: any SessionLauncher) async throws -> any RoutedSession {
        if let running = restores[id] {
            return try await running.value
        }
        let restore = Task { try await launcher.restoreSession(id: id) }
        restores[id] = restore
        defer { restores[id] = nil }
        return try await restore.value
    }

    /// The recorded summary of the session `id`, which the resolver read
    /// when it decided to restore the session.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - recorded: The recorded summaries that the resolver read.
    /// - Returns: The summary.
    /// - Throws: `SessionDirectoryError.unknownSession(_:)` when `recorded`
    ///   holds no summary with the id, which the resolver never decides.
    private static func recordedSummary(of id: ULID, in recorded: [SessionSummary]) throws -> SessionSummary {
        guard let summary = recorded.first(where: { $0.id == id }) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return summary
    }

    /// Starts a root session of the agent through the launcher with
    /// `message` as its first message, keeps the message in the ledger of
    /// the new session, and sends `messageDelivered`.
    ///
    /// - Parameters:
    ///   - agentID: The agent of the address.
    ///   - folder: The folder of the address, else the folder of the sender
    ///     session, or `nil` for a user sender with no folder.
    ///   - message: The message.
    /// - Returns: The `started` receipt, with the new session as its target.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, the error of the launcher, the error of a write of the
    ///   facts of the session, the refusal of the first mail, or the error of
    ///   a read of the ledger of the new session.
    private func startAgent(
        _ agentID: String, in folder: URL?, for message: OutgoingSessionMessage
    ) async throws -> SessionSendReceipt {
        let request = SessionStartRequest(
            agentID: agentID, workingDirectory: folder, firstMessage: message.text,
            startedBy: message.from.sessionID, origin: .message)
        let messageID = MailID()
        let session = try await launch(
            request,
            firstMail: mail(id: messageID, carrying: message.text, from: request.startedBy, inReplyTo: message.inReplyTo))
        let delivered = Self.delivered(message, id: messageID, to: session.id)
        keep(delivered, in: try ledger(of: session.id, in: Self.ledgerDirectory(of: session)))
        return SessionSendReceipt(messageID: messageID, target: session.id, outcome: .started)
    }

    /// The record of `message` as the directory delivers it to `target` now.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - id: The id of the mail that carries it. The default is a new id.
    ///   - target: The session id of the target.
    /// - Returns: The delivered message, not read, with the chain depth
    ///   ``firstChainDepth``.
    private static func delivered(
        _ message: OutgoingSessionMessage, id: MailID = MailID(), to target: ULID
    ) -> SessionMessage {
        SessionMessage(
            id: id, from: message.from, to: target, text: message.text, inReplyTo: message.inReplyTo,
            sentAt: Date(), chainDepth: firstChainDepth)
    }

    /// Records `delivered` in `ledger`, the ledger of its target, holds the
    /// ledger, and sends `messageDelivered`.
    ///
    /// - Parameters:
    ///   - delivered: The delivered message.
    ///   - ledger: The ledger of the target of `delivered`.
    private func keep(_ delivered: SessionMessage, in ledger: SessionMessageLedger) {
        var ledger = ledger
        ledger.record(delivered)
        ledgers[delivered.to] = ledger
        emit(.messageDelivered(delivered))
    }

    /// See `SessionDirectory.inbox(of:markRead:)`. Reads the ledger of the
    /// session: the ledger the directory holds, else the ledger in the
    /// recording directory of the live session, else the ledger in the
    /// folder of a recorded session under the recording roots of the host.
    ///
    /// A read message never starts a turn (ROUTER-5). The mail of a message
    /// to a working session waits in the session's own mail queue, so with
    /// `markRead` each marked message whose mail still waits there leaves
    /// the queue through ``RoutedSession/cancel(_:)``
    /// (``withdrawWaitingMail(_:from:)``). The transcript of the session
    /// keeps the cancel record, and the mail gets its terminal event
    /// ``SessionEvent/cancelled(_:)``. A cancel is a signal of the session,
    /// which runs after the signals before it: a mail that the pump of the
    /// session takes before the cancel runs is delivered anyway, and its
    /// message stays read in the ledger. That is the trade-off the user
    /// accepted on ROUTER-5 when the mail went to the queue of the session.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read, and withdraw their
    ///     mail that still waits.
    /// - Returns: The messages to the session that were not read, the
    ///   oldest first.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id,
    ///   ``SessionMessageLedgerError/corruptLine(_:)`` when the
    ///   `messages.jsonl` of the session is damaged before its final line, the
    ///   file-system error of a read of the ledger, or the error of the
    ///   recording roots of the host.
    public func inbox(of id: ULID, markRead: Bool) async throws -> [SessionMessage] {
        guard var ledger = try await knownLedger(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        let unread = ledger.unread
        guard markRead else {
            ledgers[id] = ledger
            return unread
        }
        ledger.markRead(unread.map(\.id))
        ledgers[id] = ledger
        await withdrawWaitingMail(unread.map(\.id), from: id)
        return unread
    }

    /// Cancels the mail of each message of `ids` that still waits in the
    /// mail queue of the live session `id` (``RoutedSession/cancel(_:)``).
    /// A mail the pump took is not in the queue, and gets no cancel. A
    /// session that is not live has no queue, so nothing changes.
    ///
    /// - Parameters:
    ///   - ids: The ids of the messages that the inbox marked read.
    ///   - id: The session id of their target.
    private func withdrawWaitingMail(_ ids: [MailID], from id: ULID) async {
        guard !ids.isEmpty, let session = liveSession(id) else { return }
        let waiting = Set(await session.pendingMessages().map(\.id))
        for mailID in ids where waiting.contains(mailID) {
            session.cancel(mailID)
        }
    }

    /// See `SessionDirectory.message(_:to:)`. Reads the ledger of
    /// `recipient` as ``inbox(of:markRead:)`` does. It never throws
    /// `unknownSession`, unlike ``inbox(of:markRead:)``, and marks nothing
    /// read.
    ///
    /// - Parameters:
    ///   - id: The id of the message.
    ///   - recipient: The session id that the message went to.
    /// - Returns: The message, read or not read, or `nil` when no message to
    ///   `recipient` has the id or no session has the id `recipient`.
    /// - Throws: ``SessionMessageLedgerError/corruptLine(_:)`` when the
    ///   `messages.jsonl` of `recipient` is damaged before its final line, the
    ///   file-system error of a read of the ledger, or the error of the
    ///   recording roots of the host.
    public func message(_ id: MailID, to recipient: ULID) async throws -> SessionMessage? {
        try await knownLedger(of: recipient)?.message(id)
    }

    /// The ledger of the session `id`, when a live session or a recorded
    /// session folder has the id.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The ledger, or `nil` when no live session and no session
    ///   folder under the recording roots has the id.
    /// - Throws: The error of a read of the ledger, or the error of the
    ///   recording roots of the host.
    private func knownLedger(of id: ULID) async throws -> SessionMessageLedger? {
        if let session = liveSession(id) {
            return try ledger(of: id, in: Self.ledgerDirectory(of: session))
        }
        guard let folder = try await recordedFolder(of: id) else { return nil }
        return try ledger(of: id, in: folder)
    }

    /// The ledger of the session `id`: the one the directory holds, else the
    /// one read from `directory`.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - directory: The recording directory of a durable session, or `nil`
    ///     for a memory-only session.
    /// - Returns: The ledger.
    /// - Throws: ``SessionMessageLedgerError/corruptLine(_:)`` for a
    ///   `messages.jsonl` damaged before its final line, or the file-system
    ///   error of a read of it.
    private func ledger(of id: ULID, in directory: URL?) throws -> SessionMessageLedger {
        if let held = ledgers[id] {
            return held
        }
        return try SessionMessageLedger.load(from: directory)
    }

    /// The folder of the recorded session `id` under the recording roots of
    /// the host: the folder named by the id in the first root that holds one.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The folder, or `nil` when no root holds one.
    /// - Throws: The error of the recording roots of the host.
    private func recordedFolder(of id: ULID) async throws -> URL? {
        try await recordingRoots()
            .map { $0.appendingPathComponent(id.description, isDirectory: true) }
            .first { folder in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
    }

    /// The recording directory that holds the ledger of `session`: its
    /// recording directory when it records durably, else `nil`, because a
    /// memory-only session writes nothing to disk.
    ///
    /// - Parameter session: A live session.
    /// - Returns: The recording directory, or `nil` for a memory-only
    ///   session.
    private static func ledgerDirectory(of session: any RoutedSession) -> URL? {
        guard let actor = session as? RoutedSessionActor, actor.sidecarOrigin.recordsFacts else { return nil }
        return session.recordingDirectory
    }

    /// The live session `id`.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The session, or `nil` when the directory holds no live
    ///   session with the id.
    private nonisolated func liveSession(_ id: ULID) -> (any RoutedSession)? {
        state.withLock { $0.entries[id]?.session }
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
    /// the registry. ``send(_:)`` sends `messageDelivered` through it, and
    /// the archive card sends `archived` through it.
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

    // MARK: - State

    /// The task that follows the state of the registered session `id`
    /// (``followState(of:reading:)``).
    ///
    /// - Parameter id: The session id.
    /// - Returns: The task, or `nil` when the directory holds no entry for
    ///   `id`.
    nonisolated func stateFeed(of id: ULID) -> Task<Void, Never>? {
        state.withLock { $0.entries[id]?.stateFeed }
    }

    /// The feed of the events of `session`, made at once for a
    /// ``RoutedSessionActor``.
    ///
    /// `streamSessionEvents()` is isolated to the session, and the
    /// registration is synchronous. The feed of a ``RoutedSessionActor``
    /// comes from its `nonisolated` output hub, the same feed
    /// `streamSessionEvents()` makes, so the directory misses no event
    /// between the registration and the first read. Another session gets
    /// its feed in the task that reads it.
    ///
    /// - Parameter session: The registered session.
    /// - Returns: The feed, or `nil` for a session that is not a
    ///   ``RoutedSessionActor``.
    private static func makeEventFeed(of session: any RoutedSession) -> AsyncStream<SessionOutput>? {
        (session as? RoutedSessionActor)?.outputHub.makeFeed()
    }

    /// Starts the one task that reads the events of `session` and applies
    /// each of them to the state of its entry (``recordState(after:of:)``).
    ///
    /// The task holds neither the session nor the directory: it ends when
    /// the feed ends, which ``RoutedSession/close()`` and the release of a
    /// ``RoutedSessionActor`` both do, or when the directory cancels it
    /// (``unregister(_:)``, or a new registration of the id).
    ///
    /// - Parameters:
    ///   - session: The registered session.
    ///   - feed: The feed of its events from ``makeEventFeed(of:)``, or
    ///     `nil` to make it in the task.
    /// - Returns: The task.
    private nonisolated func followState(
        of session: any RoutedSession, reading feed: AsyncStream<SessionOutput>?
    ) -> Task<Void, Never> {
        let id = session.id
        return Task { [weak self, weak session] in
            guard let outputs = await Self.events(from: feed, of: session) else { return }
            for await output in outputs {
                await self?.recordState(after: output.event, of: id)
            }
        }
    }

    /// The feed to read: `feed` when the registration made one, else a new
    /// feed of `session`.
    ///
    /// - Parameters:
    ///   - feed: The feed that the registration made, or `nil`.
    ///   - session: The session, or `nil` when it is gone.
    /// - Returns: The feed, or `nil` when there is none and the session is
    ///   gone.
    private static func events(
        from feed: AsyncStream<SessionOutput>?, of session: (any RoutedSession)?
    ) async -> AsyncStream<SessionOutput>? {
        guard let feed else { return await session?.streamSessionEvents() }
        return feed
    }

    /// Applies `event` to the state of the session `id`, and sends
    /// `stateChanged` with the state and the idle summary
    /// (``SessionStateTracking/idleSummary``) when either changed, under the
    /// lock of the registry. The time of the change becomes the time of the
    /// last change of the session. An answer while the session works
    /// changes only the stored last summary, which the event does not carry,
    /// so it sends nothing.
    ///
    /// At a work end, the open questions of the session itself replace the
    /// open questions the tracking holds, because a form answer of the
    /// client sends no event that names its question
    /// (``SessionStateTracking``). An id with no live entry, and a task the
    /// directory cancelled, change nothing.
    ///
    /// - Parameters:
    ///   - event: An event of the session.
    ///   - id: The session id.
    private nonisolated func recordState(after event: SessionEvent, of id: ULID) async {
        let openQuestions = event == .workEnded ? await openQuestions(of: id) : nil
        state.withLock { registry in
            guard !Task.isCancelled, var entry = registry.entries[id], entry.session != nil else { return }
            let before = (entry.tracking.state, entry.tracking.idleSummary)
            if let openQuestions {
                entry.tracking.replaceOpenQuestions(with: openQuestions)
            }
            entry.tracking.apply(event: event)
            let after = (entry.tracking.state, entry.tracking.idleSummary)
            if after != before {
                entry.updatedAt = Date()
                registry.fanout.send(.stateChanged(id: id, state: after.0, lastSummary: after.1))
            }
            registry.entries[id] = entry
        }
    }

    /// The questions that the live session `id` holds open
    /// (``RoutedSession/openElicitationIds()``).
    ///
    /// - Parameter id: The session id.
    /// - Returns: The ids of the open questions, or `nil` when the session is
    ///   gone.
    private nonisolated func openQuestions(of id: ULID) async -> Set<ULID>? {
        guard let session = liveSession(id) else { return nil }
        return Set(await session.openElicitationIds().compactMap { ULID($0) })
    }
}
