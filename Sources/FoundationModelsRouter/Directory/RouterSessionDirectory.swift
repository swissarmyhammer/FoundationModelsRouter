import Foundation
import FoundationModelsExtras
import Logging
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
/// For each registered durable session, one watcher also reads the `inbox/`
/// folder of the session folder (``SessionInboxWatcher``). A file that
/// arrives there is delivered as a message (``scanInbox(of:)``). The watcher
/// ends with the session: ``unregister(_:)`` and ``archive(_:by:)`` stop it.
///
/// The directory also owns the record of past sessions (D72): the root
/// session folders on disk under the recording roots of the host
/// (``useRecordingRoots(_:)``) answer as recorded summaries
/// (``RecordedSessions``).
///
/// The directory keeps the pin and the last use of each session in the
/// ``SessionUsageStore`` that the host gives with ``use(usageStore:)``
/// (ROUTER-3, D186). ``setPinned(_:of:)`` and ``markUsed(_:)`` write it, each
/// summary reads it, and ``sessions(matching:)`` filters by the pin and
/// orders by the pin or by the last use. The recording root of each usage
/// joins the recording roots of the host, so a recorded session that the
/// store knows is found after a restart.
///
/// This version answers ``sessions(matching:)`` and ``summary(of:)`` for the
/// live sessions, with the state and the last summary of each, and for the
/// recorded root sessions, ``start(_:)`` starts a root session through the
/// launcher, and ``events()`` gives `started` for each session it registers and
/// `stateChanged` for each change of what that event carries: the state, and
/// the last summary when the state is idle (`nil` with any other state, as
/// the port documents). ``summary(of:)`` reports the last summary in each
/// state. ``send(_:)`` delivers a message to each live target of its address
/// as a `Mail` by the delivery rules of ROUTER-5, writes the message as a file
/// in the inbox of a recorded target that is not live, or starts a session of
/// an agent for it, keeps each
/// delivered message in the ledger of its target (``SessionMessageLedger``,
/// ROUTER-4) with its chain depth, and sends `messageDelivered` when the
/// target gets the message (D199 (f)): when its pump takes the mail, before
/// the first output of that answer, or when an inbox read reads the message
/// while its mail waits. A message that the target does not take at once
/// (a `queued` or a `sent` receipt) also gives `messageQueued` at the send,
/// before the send returns. Each send
/// passes the loop guards of ``SessionMessageLimits`` first (ROUTER-5): the
/// chain depth, the sends of one turn, the targets of one tag send and the
/// length of the text. No guard limits the sessions that work at the same
/// time. ``inbox(of:markRead:)`` and
/// ``message(_:to:)`` read that ledger, and a read mark withdraws the mail
/// that still waits. ``addTags(_:to:)``, ``removeTags(_:from:)``,
/// ``setTitle(_:of:)`` and ``setAdditionalDirectories(to:for:)`` change the
/// ``SessionRecord`` of a live or recorded session (ROUTER-2, ROUTER-3), and
/// ``recordedSessions(in:)`` lists the records of a recording root with no
/// router. ``archive(_:by:)`` hides a live or recorded session (ROUTER-11):
/// it stops a running turn, keeps each message that waits in the queue of
/// the session as an unread message of its inbox, takes the session off the
/// live list, writes `archivedAt` to its `index.md`, and sends `archived`.
/// An archive is not final (D204): ``unarchive(_:by:)`` removes `archivedAt`
/// again, and the session is a recorded session that a host can open. The
/// session then takes the messages of its inbox. A message to an archived
/// session goes to its inbox, and the session stays archived. A root session
/// with no title gets a default name from its agent (D199 (b),
/// ``SessionDefaultTitle``) when it registers, and a recorded root session
/// with no title gets one when a read finds it. Only ``setTitle(_:of:)``
/// changes the name after that. ``fork(_:)`` makes a live fork of a session
/// at a cut of its history (D205): a top-level session of kind `fork` with
/// the name of its source and `-fork`, which the launcher builds with the
/// surface of the host and the directory holds until it closes.
public actor RouterSessionDirectory: SessionDirectory {
    /// The agent id of a session that recorded none, for example a session
    /// from before ROUTER-1: the default agent, the D71 fallback when neither
    /// the start nor the folder's `AGENT.md` names one.
    static let defaultAgentID = "default"

    /// The origin of a session that recorded none. A record with no origin
    /// is of a session an ACP `session/new` opened, so its origin is the
    /// client.
    static let defaultOrigin: FoundationModelsExtras.SessionDirectoryOrigin = .client

    /// The reason of the refused receipt of a target that the resolver found
    /// live, and that left the directory or closed before its mail went out.
    static let notLiveReason = "not live"

    /// The reason of the refused receipt of a message from a user sender
    /// (a UI send) with no source session to a recorded session that is not
    /// live. Only a user message that names its source session goes to the
    /// inbox of a recorded session (D199 (f)), so such a message needs a live
    /// session.
    static let userNeedsLiveSessionReason = "a message from a user needs a live session"

    /// The note in the `reason` of the `sent` receipt of a message to an
    /// archived session (D204). The message is in the inbox of the session,
    /// and the session stays archived.
    static let archivedNote = "archived"

    /// The chain depth of a message from a UI, from a user turn, or from a
    /// session outside a turn: the first message of a chain. A message that
    /// a turn sends has the depth of the deepest message of that turn plus
    /// one (``chainDepth(of:in:)``).
    static let firstChainDepth = 1

    /// The sends that one turn of a session made, for the guard of
    /// ``SessionMessageLimits/maxSendsPerTurn``.
    struct TurnSends {
        /// The mail ids of the turn: the ids of the origin of the turn
        /// (``OriginContext/current``). A mail that joins the turn adds its
        /// id, so the turn keeps its count.
        var mailIDs: Set<MailID>

        /// The sends that the turn made.
        var count: Int
    }



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

        /// The watcher of the `inbox/` folder of the session
        /// (``SessionInboxWatcher``), or `nil` for a memory-only session and
        /// for a folder that did not open. A durable session with `nil` here
        /// has no watcher, so a send scans its inbox (``hasNoInboxWatcher(_:)``).
        var inboxWatcher: SessionInboxWatcher?

        /// Ends the task and the watcher that the registration started. Each
        /// place that takes the entry off the registry calls this, so the
        /// two end together.
        func cancelFeeds() {
            stateFeed?.cancel()
            inboxWatcher?.cancel()
        }
    }

    /// A message whose mail waits in the queue of its target for the
    /// delivery (``Registry/awaitingDelivery``), with the header line that
    /// starts its prompt. An archive writes both to the inbox file of the
    /// message when it keeps the message (D204).
    struct AwaitedDelivery {
        /// The delivered message, as the ledger of its target keeps it.
        let message: SessionMessage

        /// The header of a user message that names its source session
        /// (``UserMessageHeader``), or `nil`.
        let userHeader: UserMessageHeader?
    }

    /// What the directory keeps under its one lock: the live registry and
    /// the open event streams. One lock keeps both, so an event that a change
    /// of the registry sends reaches each stream in the order of the changes.
    struct Registry {
        /// The live registry, keyed by session id.
        var entries: [ULID: Entry] = [:]

        /// The open streams of ``RouterSessionDirectory/events()``.
        var fanout = SessionDirectoryEventFanout()

        /// Each message whose mail waits in the queue of its target for the
        /// delivery, by the id of the message
        /// (``RouterSessionDirectory/sendWhenDelivered(_:userHeader:to:)``).
        /// The `messageDelivered` event of the message goes out when it
        /// leaves this map as delivered.
        var awaitingDelivery: [MailID: AwaitedDelivery] = [:]

        /// Each session that an archive stops now, with each message whose
        /// mail the stop took out of the queue of the session with no
        /// delivery (``apply(_:)``). The archive keeps these messages in the
        /// inbox of the session (``takeKeptMail(of:)``, D204).
        var keptMail: [ULID: [AwaitedDelivery]] = [:]

        /// Each message of a `queued` receipt whose `messageQueued` event
        /// did not go out yet, by the id of the message
        /// (``RouterSessionDirectory/hand(_:userHeader:to:ledger:isQueued:)``).
        /// The send puts the message here before it puts the mail in the
        /// queue of the target, and sends the event when the put is done. A
        /// refused mail removes the message with no event
        /// (``forgetRefusedMail(_:)``). Only the send removes a message from
        /// this map, so a send that returns a `queued` receipt gives exactly
        /// one `messageQueued`, also when the target cancels or loses the
        /// mail during the send (``apply(_:)``).
        ///
        /// The pump of the target can take the mail before the send sends the
        /// event. Then ``sendDelivered(_:)`` sends `messageQueued` first, so
        /// `messageQueued` always comes before `messageDelivered`.
        var awaitingQueuedEvent: [MailID: SessionMessage] = [:]

        /// Applies `fate` to ``awaitingDelivery``: a delivered mail sends the
        /// `messageDelivered` event of its message (``sendDelivered(_:)``),
        /// and a mail that ended with no delivery removes its message with
        /// no event. When an archive stops the target, that message goes to
        /// ``keptMail``.
        ///
        /// It does not remove a message from ``awaitingQueuedEvent``. The
        /// target reports the fate of its mail on its own executor, so a
        /// cancel or a loss can come after the put and before the send sends
        /// `messageQueued`. The send then still returns a `queued` receipt,
        /// and the event must go out.
        ///
        /// - Parameter fate: The fate of one mail of a session.
        mutating func apply(_ fate: MailFate) {
            switch fate {
            case .delivered(let id):
                sendDelivered(id)
            case .cancelledOrLost(let id):
                guard let awaited = awaitingDelivery.removeValue(forKey: id) else { return }
                keptMail[awaited.message.to]?.append(awaited)
            }
        }

        /// Starts to keep the mail of the session `id` that ends with no
        /// delivery (``keptMail``): an archive of the session begins.
        ///
        /// - Parameter id: The session id.
        mutating func startKeepingMail(of id: ULID) {
            keptMail[id] = []
        }

        /// Ends the keep of the mail of the session `id`, and takes each
        /// message to it whose mail ended with no delivery since
        /// ``startKeepingMail(of:)``, and each message to it whose mail still
        /// waits for its delivery. These messages leave ``awaitingDelivery``
        /// with no event.
        ///
        /// - Parameter id: The session id.
        /// - Returns: The kept messages.
        mutating func takeKeptMail(of id: ULID) -> [AwaitedDelivery] {
            let kept = keptMail[id] ?? []
            let waiting = awaitingDelivery.values.filter { $0.message.to == id }
            forgetDeliveries(to: id)
            return kept + waiting
        }

        /// Removes the message `id` from ``awaitingDelivery`` and from
        /// ``awaitingQueuedEvent``, with no event, when the target refuses
        /// its mail. The send then gives no `queued` receipt, so the message
        /// gives no message event.
        ///
        /// - Parameter id: The id of a message.
        mutating func forgetRefusedMail(_ id: MailID) {
            awaitingDelivery.removeValue(forKey: id)
            awaitingQueuedEvent.removeValue(forKey: id)
        }

        /// Removes the message `id` from ``awaitingQueuedEvent``, and sends
        /// its `messageQueued` event. An id that does not wait changes
        /// nothing, so each message gives one event at most.
        ///
        /// - Parameter id: The id of a message.
        mutating func sendQueued(_ id: MailID) {
            guard let queued = awaitingQueuedEvent.removeValue(forKey: id) else { return }
            fanout.send(.messageQueued(queued))
        }

        /// Removes the message `id` from ``awaitingDelivery``, and sends its
        /// `messageDelivered` event. An id that does not wait changes
        /// nothing, so each message gives one event at most. A
        /// `messageQueued` event of the message that did not go out yet goes
        /// out first (``sendQueued(_:)``).
        ///
        /// - Parameter id: The id of a message.
        mutating func sendDelivered(_ id: MailID) {
            guard let delivered = awaitingDelivery.removeValue(forKey: id) else { return }
            sendQueued(id)
            fanout.send(.messageDelivered(delivered.message))
        }

        /// Removes each message of ``awaitingDelivery`` to the session `id`,
        /// with no event, when the session leaves the live list, and ends
        /// the keep of its mail (``keptMail``).
        ///
        /// It does not touch ``awaitingQueuedEvent``: only the send that put a
        /// message there removes it, before the send returns. It sends the
        /// event of a put that is done (``sendQueued(_:)``), and removes the
        /// message of a refused mail with no event (``forgetRefusedMail(_:)``).
        /// Thus the `messageQueued` event of a `queued` receipt goes out also
        /// when the target closes during the send.
        ///
        /// - Parameter id: The session id.
        mutating func forgetDeliveries(to id: ULID) {
            awaitingDelivery = awaitingDelivery.filter { $0.value.message.to != id }
            keptMail[id] = nil
        }

        /// The ids of the sessions that this process saw suspended
        /// (``RoutedSession/suspend()``): when ``RouterSessionDirectory/suspendLiveSessions()``
        /// ran, or when the session left the live list while it was suspended.
        /// A close takes a session off the live list, so this set is what
        /// keeps the suspend known to ``RouterSessionDirectory/markEnded(_:reason:)``
        /// after the close. It is never cleared, but a new live registration
        /// of an id removes the id: a restored session starts not suspended.
        var suspendedIDs: Set<ULID> = []

        /// Each fork that ``RouterSessionDirectory/fork(_:)`` made and that is
        /// still on the live list, by id (D205). The directory holds each
        /// other session weakly, because its host holds it. No host holds a
        /// fork that the directory made, so the directory holds it here until
        /// it leaves the live list (``RouterSessionDirectory/unregister(_:)``:
        /// its close, its archive) or until ``RouterSessionDirectory/shutdown()``.
        var heldForks: [ULID: any RoutedSession] = [:]

        /// The store of the pin and the last use of each session (ROUTER-3,
        /// D186), or `nil` before ``RouterSessionDirectory/use(usageStore:)``.
        /// The lock keeps it, so a summary that the lock builds reads it.
        var usageStore: (any SessionUsageStore)?

        /// The usage of the session `id` in ``usageStore``.
        ///
        /// - Parameter id: The session id.
        /// - Returns: The usage, or `nil` when there is no store or the store
        ///   keeps no usage for `id`.
        func usage(of id: ULID) -> SessionUsage? {
            usageStore?.usage(of: id)
        }
    }

    /// The registry and the event streams. A lock keeps them, so the
    /// synchronous ``register(_:kind:parentID:requestedByClient:)`` and
    /// ``unregister(_:)`` need no `await`.
    private let state = Mutex<Registry>(Registry())

    /// Makes the default naming of a session (``SessionDefaultTitle``) one
    /// step at a time: the naming and the registration of a new root session
    /// (``register(_:kind:parentID:requestedByClient:)``), and the naming of
    /// the recorded sessions that a read finds with no title
    /// (``recordedSummaries()``). Thus two sessions in one folder never get
    /// the same default name. The lock is held across the read and the write
    /// of `index.md` files. It is always taken before the lock of ``state``,
    /// never under it, thus the lock of ``state`` never waits on the file
    /// system.
    private let naming = Mutex<Void>(())

    /// The count of the inbox watchers that are open. Only a test reads it
    /// (``openInboxWatcherCount``).
    private let openInboxWatchers = SessionInboxWatcherCount()

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

    /// The loop guards that ``send(_:)`` applies to each message (ROUTER-5).
    private let limits: SessionMessageLimits

    /// The sends of the last turn of each session that sent from a turn, by
    /// session id (``countSend(from:in:)``). A new turn of the session
    /// replaces the entry, so a session holds one entry at most.
    private var turnSends: [ULID: TurnSends] = [:]

    /// Makes an empty directory.
    ///
    /// - Parameter limits: The loop guards of each send. The default is the
    ///   default guards of ``SessionMessageLimits``; a test lowers them.
    public init(limits: SessionMessageLimits = SessionMessageLimits()) {
        self.limits = limits
    }

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
    /// A durable session also gets the watcher of its `inbox/` folder
    /// (``SessionInboxWatcher``), so a file that arrives there is delivered
    /// (``scanInbox(of:)``). The folder is made and opened before the lock,
    /// and the watcher runs after it, because the lock must not wait on the
    /// file system. A session that a host restores registers itself, so it
    /// starts the watcher too. A memory-only session has no folder and no
    /// watcher.
    /// One directory delivers the files of one session. The code does not
    /// enforce this: it makes no check of the recording root and no claim on
    /// a file. Two directories that watch one folder can both deliver a file,
    /// so the host must not run two live copies of one session. A file in the
    /// inbox of a recorded session that is not live waits: no watcher covers
    /// it, and no file restores the session, until a process opens the session.
    /// Then the first scan of the watcher delivers the file.
    ///
    /// The registration makes the directory the observer of the fate of
    /// each mail of the session (``RoutedSessionActor/observeMailFate(_:)``),
    /// so a delivered message gives its `messageDelivered` event when the
    /// pump takes its mail (``sessionDidReport(_:)``).
    ///
    /// A second registration of a session that is still live replaces its
    /// kind and its parent, and keeps its time of change, its state, its
    /// feed task and its watcher. It sends no second `started` and starts no
    /// second watcher.
    ///
    /// A registration of another session object with the id of a live session
    /// is a replacement, not a second registration. A restore makes it: a host
    /// suspends a session, keeps the object, and restores the same id, also
    /// onto another model. The new object gets its own `started`, its own
    /// feed task and its own watcher, and the id is no more suspended.
    ///
    /// A root session with no title gets its default name before the lock
    /// (``giveDefaultTitle(to:kind:parentID:)``, D199 (b)), thus its `started`
    /// holds the name. This covers each start of a root session:
    /// `session/new` of a client, ``start(_:)`` and the start of an agent
    /// address, and also a restored root session with no title. A fork that
    /// ``fork(_:)`` makes gets the fork name of its source in the same way
    /// (D205); a restored fork keeps the facts of its record.
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
        register(session, kind: kind, parentID: parentID, requestedByClient: requestedByClient, namingFork: false)
    }

    /// ``register(_:kind:parentID:requestedByClient:)``, with the choice to
    /// give a new fork with no title its fork name (D205). Only
    /// ``fork(_:)`` names a fork: a restored fork keeps the facts of its
    /// record.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - kind: The kind of the session.
    ///   - parentID: The parent of a subagent, or the original session of a
    ///     fork; `nil` for a root session.
    ///   - requestedByClient: The UI client that asked for the start, or
    ///     `nil`.
    ///   - namingFork: `true` to give a fork with no title its fork name.
    private nonisolated func register(
        _ session: any RoutedSession, kind: SessionKind, parentID: ULID?, requestedByClient: String?,
        namingFork: Bool
    ) {
        var entry = Entry(session: session, kind: kind, parentID: parentID, updatedAt: session.id.timestamp)
        let watcher = openInboxWatcher(of: session)
        (session as? RoutedSessionActor)?.observeMailFate { [weak self] fate in self?.sessionDidReport(fate) }
        let isNew = naming.withLock { _ in
            giveDefaultTitle(to: session, kind: kind, parentID: namingFork ? parentID : nil)
            return state.withLock { registry in
                if let live = registry.entries[session.id], live.session === session {
                    entry.updatedAt = live.updatedAt
                    entry.tracking = live.tracking
                    entry.stateFeed = live.stateFeed
                    entry.inboxWatcher = live.inboxWatcher
                    registry.entries[session.id] = entry
                    return false
                }
                registry.entries[session.id]?.cancelFeeds()
                registry.suspendedIDs.remove(session.id)
                entry.stateFeed = followState(of: session, reading: Self.makeEventFeed(of: session))
                entry.inboxWatcher = watcher
                registry.entries[session.id] = entry
                let summary = Self.summary(of: session, in: entry, usage: registry.usage(of: session.id))
                registry.fanout.send(.started(summary, requestedByClient: requestedByClient))
                return true
            }
        }
        if isNew {
            watcher?.start()
        } else {
            watcher?.cancel()
        }
    }

    /// Applies the fate of one mail that a live session reports
    /// (``RoutedSessionActor/observeMailFate(_:)``) to the messages that
    /// wait for their delivery, under the lock of the registry
    /// (``Registry/apply(_:)``). The session calls this before any reader of
    /// its output gets the event of the fate, so the `messageDelivered`
    /// event of a message comes before each output of the answer that
    /// delivers it.
    ///
    /// - Parameter fate: The fate of the mail.
    private nonisolated func sessionDidReport(_ fate: MailFate) {
        state.withLock { $0.apply(fate) }
    }

    /// Opens the watcher of the `inbox/` folder of a session, which does not
    /// run yet.
    ///
    /// - Parameter session: The session to register.
    /// - Returns: The watcher, or `nil` for a memory-only session and for a
    ///   folder that did not open. The second case is logged, and the
    ///   session goes on with no watcher: a send to it scans the inbox at
    ///   once (``deliver(_:chainDepth:userHeader:to:)``), but a file that a hand puts
    ///   in the inbox waits for a call of ``scanInbox(of:)``.
    private nonisolated func openInboxWatcher(of session: any RoutedSession) -> SessionInboxWatcher? {
        guard let folder = Self.ledgerDirectory(of: session) else { return nil }
        let id = session.id
        do {
            return try SessionInboxWatcher(sessionFolder: folder, count: openInboxWatchers) { [weak self] in
                Task { await self?.scanInbox(of: id) }
            }
        } catch {
            logInboxFailure("the inbox folder of a session did not open for watching", error, session: id, file: nil)
            return nil
        }
    }

    /// Gives a root session or a fork with no title its default name
    /// (``SessionDefaultTitle``), through its facts, which writes the name to
    /// its `index.md`: the name of its agent for a root session, and the name
    /// of its source with `-fork` for a fork (D205). A session with a title
    /// keeps it, and a session of another kind gets no name. The caller holds
    /// the lock of ``naming``.
    ///
    /// The used names come from the live sessions and from the sessions
    /// recorded in the recording root of the session and in the recording
    /// roots of the usage store (``recordedSummaries(besides:)``). The
    /// recording roots of the host need an `await`, and a registration does
    /// not wait, thus a session that only a root of the host holds does not
    /// count.
    ///
    /// A session that cannot change its facts gets no default name. The
    /// failure is logged, and the registration goes on.
    ///
    /// - Parameters:
    ///   - session: The session to register.
    ///   - kind: The kind of the session.
    ///   - parentID: The source of a fork that ``fork(_:)`` makes, or `nil`.
    ///     A fork with no source here gets no name: a restored fork keeps
    ///     the facts of its record.
    private nonisolated func giveDefaultTitle(to session: any RoutedSession, kind: SessionKind, parentID: ULID?) {
        let namesFork = kind == .fork && parentID != nil
        guard kind == .root || namesFork, SessionDefaultTitle.isMissing(in: session.facts) else { return }
        let actor: RoutedSessionActor
        do {
            actor = try Self.recordOwner(of: session)
        } catch {
            Self.logSession(
                .error,
                "a new session did not get its default name because it cannot change its facts; it registers with no title",
                session: session.id, error: error)
            return
        }
        let summaries = liveSummaries() + recordedSummaries(besides: session)
        let title =
            if namesFork, let parentID {
                SessionDefaultTitle.makeFork(
                    of: parentID, for: session.id, in: session.workingDirectory, among: summaries)
            } else {
                SessionDefaultTitle.make(
                    for: session.facts, of: session.id, in: session.workingDirectory, among: summaries)
            }
        actor.updateFacts { $0.title = title }
    }

    /// The summaries of the root sessions and the forks recorded in the
    /// recording root of `session` (the root that holds its folder, also for
    /// a fork that nests in the folder of its source) and in the recording
    /// roots of the usage store, with no `await`
    /// (``RecordedSessions/summaries()``). A recorded fork that is not live
    /// counts, so a new fork of the same source does not get its name. A root that does not read is logged and gives
    /// no summary, because the default name of a new session must not stop
    /// its registration.
    ///
    /// - Parameter session: A root session or a fork that registers.
    /// - Returns: The recorded summaries, in no order.
    private nonisolated func recordedSummaries(besides session: any RoutedSession) -> [SessionSummary] {
        let ownRoot = TranscriptTree.recordingRoot(ofSessionIn: session.recordingDirectory)
        let roots = [ownRoot] + usageStoreRecordingRoots()
        do {
            return try RecordedSessions(roots: roots).summaries()
        } catch {
            Self.logSession(
                .error,
                "the recorded sessions did not read for the default name of a new session; only the live sessions count",
                session: session.id, error: error)
            return []
        }
    }

    /// Takes a session off the live list, ends the task that follows its
    /// state, and stops the watcher of its inbox. Each message to it that
    /// waits for its delivery gives no event
    /// (``Registry/forgetDeliveries(to:)``). The directory releases its hold
    /// on a fork that it made (``Registry/heldForks``). An id the directory
    /// does not hold changes nothing.
    ///
    /// - Parameter id: The session id.
    ///
    /// A session that is suspended when it leaves is remembered as suspended
    /// (``Registry/suspendedIDs``), so a later ``markEnded(_:reason:)`` for
    /// it still throws.
    nonisolated func unregister(_ id: ULID) {
        let releasedFork = state.withLock { registry -> (any RoutedSession)? in
            let releasedFork = registry.heldForks.removeValue(forKey: id)
            guard let entry = registry.entries.removeValue(forKey: id) else { return releasedFork }
            if entry.session?.isSuspended == true {
                registry.suspendedIDs.insert(id)
            }
            entry.cancelFeeds()
            registry.forgetDeliveries(to: id)
            return releasedFork
        }
        // Released after the lock: the last release of a fork runs its
        // `deinit`, which must not run under the lock of the registry.
        withExtendedLifetime(releasedFork) {}
    }

    /// The summaries of every live session, in no order. An entry whose
    /// session is gone is dropped from the registry here, and the task that
    /// follows its state ends.
    ///
    /// - Returns: One summary for each live session.
    private nonisolated func liveSummaries() -> [SessionSummary] {
        state.withLock { registry in
            for gone in registry.entries.values where gone.session == nil {
                gone.cancelFeeds()
            }
            registry.entries = registry.entries.filter { $0.value.session != nil }
            let usages = registry.usageStore?.usages() ?? [:]
            return registry.entries.compactMap { id, entry in Self.summary(of: entry, usage: usages[id]) }
        }
    }

    /// The summary of one registered session, or `nil` when the session is
    /// gone.
    ///
    /// - Parameters:
    ///   - entry: The registry entry.
    ///   - usage: The usage of the session in the usage store, or `nil`.
    /// - Returns: The summary.
    private static func summary(of entry: Entry, usage: SessionUsage?) -> SessionSummary? {
        entry.session.map { summary(of: $0, in: entry, usage: usage) }
    }

    /// The summary of a live session, from its `nonisolated` properties, its
    /// facts and its registry entry, with no `await`.
    ///
    /// The state is the tracked work state, or `archived` when the facts of
    /// the session hold `archivedAt`: a live session whose record says it is
    /// archived reads as archived, so the resolver sends a message to it to
    /// its inbox, and the message starts no turn (D204).
    /// ``SessionSummary/archivedAt`` is the `archivedAt` of the facts.
    /// The pin and the last use come from `usage` (``use(usageStore:)``).
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - entry: The registry entry of `session`.
    ///   - usage: The usage of the session in the usage store, or `nil` when
    ///     the store keeps none or the directory has no store.
    /// - Returns: The summary.
    private static func summary(
        of session: any RoutedSession, in entry: Entry, usage: SessionUsage?
    ) -> SessionSummary {
        let facts = session.facts
        return SessionSummary(
            id: session.id,
            agentID: facts.agentID ?? defaultAgentID,
            agentName: facts.agentName,
            workingDirectory: session.workingDirectory,
            title: SessionDefaultTitle.given(facts.title),
            tags: facts.tags,
            kind: entry.kind,
            state: facts.archivedAt == nil ? entry.tracking.state : .archived,
            parentID: entry.parentID,
            startedBy: facts.startedBy,
            origin: facts.origin ?? defaultOrigin,
            createdAt: session.id.timestamp,
            updatedAt: entry.updatedAt,
            lastSummary: entry.tracking.lastSummary,
            isLive: true,
            pinnedAt: usage?.pinnedAt,
            lastUsedAt: usage?.lastUsedAt,
            archivedAt: facts.archivedAt)
    }

    // MARK: - Query

    /// See `SessionDirectory.sessions(matching:)`. The live sessions answer,
    /// and with `includesRecorded` the root sessions on disk under the
    /// recording roots too (``RecordedSessions``); a session that is live and
    /// recorded answers once, as live. The result is in the order of `query`
    /// (``ordered(_:by:)``), cut to the limit of `query`. Each summary has the
    /// pin and the last use of the usage store (``use(usageStore:)``).
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
        return Array(Self.ordered(matching, by: query.order).prefix(max(0, query.limit)))
    }

    /// Puts summaries in the order of a query.
    ///
    /// - `newestFirst`: the newest first (ULID order), as `newestFirst` holds
    ///   them.
    /// - `pinOrder`: the first pin first, then the sessions that are not
    ///   pinned, the newest first.
    /// - `lastUsedFirst`: the last use first, then the sessions that have no
    ///   use, the newest first.
    ///
    /// - Parameters:
    ///   - newestFirst: The summaries, the newest first.
    ///   - order: The order of the query.
    /// - Returns: The summaries in `order`.
    private static func ordered(_ newestFirst: [SessionSummary], by order: SessionOrder) -> [SessionSummary] {
        switch order {
        case .newestFirst:
            return newestFirst
        case .pinOrder:
            return sorted(newestFirst, by: \.pinnedAt, earliestFirst: true)
        case .lastUsedFirst:
            return sorted(newestFirst, by: \.lastUsedAt, earliestFirst: false)
        }
    }

    /// Sorts summaries by a time. The summaries with no time come after the
    /// others. The sort is stable, so equal times and the summaries with no
    /// time keep the order of `summaries`.
    ///
    /// - Parameters:
    ///   - summaries: The summaries, the newest first.
    ///   - time: The time to sort by.
    ///   - earliestFirst: `true` for the earliest time first, `false` for the
    ///     latest time first.
    /// - Returns: The sorted summaries.
    private static func sorted(
        _ summaries: [SessionSummary], by time: KeyPath<SessionSummary, Date?>, earliestFirst: Bool
    ) -> [SessionSummary] {
        let timed = summaries
            .compactMap { summary in summary[keyPath: time].map { (time: $0, summary: summary) } }
            .sorted { earliestFirst ? $0.time < $1.time : $0.time > $1.time }
        return timed.map(\.summary) + summaries.filter { $0[keyPath: time] == nil }
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
            registry.entries[id].flatMap { Self.summary(of: $0, usage: registry.usage(of: id)) }
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
            query.pinned.map { $0 == summary.isPinned },
        ]
        return checks.allSatisfy { $0 ?? true }
    }

    /// The summaries of the root sessions and the forks on disk under the
    /// recording roots of the host (``useRecordingRoots(_:)``) and of the
    /// usage store (``allRecordingRoots()``), each with the pin and the last
    /// use of the usage store (``RecordedSessions/listedEntries()``). A
    /// recorded fork is a `fork` of its source, also when its folder sits
    /// inside the folder of its source (D205). A recorded root session with
    /// no title gets its default name here (``namingUntitled(_:)``).
    ///
    /// - Returns: One summary for each recorded root session and each
    ///   recorded fork, in no order.
    /// - Throws: The error of the recording roots of the host, or of a read
    ///   of the record of past sessions.
    private func recordedSummaries() async throws -> [SessionSummary] {
        let usages = currentUsageStore()?.usages() ?? [:]
        let entries = try RecordedSessions(roots: try await allRecordingRoots()).listedEntries()
        return naming.withLock { _ in namingUntitled(entries) }
            .map { Self.withUsage($0, usages[$0.id]) }
    }

    /// The summaries of recorded sessions (``RecordedSessions/listedEntries()``).
    /// Each root session with no
    /// title that is not live gets its default name (``SessionDefaultTitle``,
    /// D199 (b)), and the name is written to its `index.md`, thus the next
    /// read gives the same name. A save that fails is logged, and the summary
    /// holds the name all the same. The oldest session is named first, and
    /// each name counts for the next. A live session got its name when it
    /// registered. The caller holds the lock of ``naming``.
    ///
    /// - Parameter entries: The recorded sessions, newest first.
    /// - Returns: One summary for each entry, in the order of `entries`.
    private nonisolated func namingUntitled(_ entries: [RecordedSessions.Entry]) -> [SessionSummary] {
        let live = liveSummaries()
        let liveIDs = Set(live.map(\.id))
        var recorded = entries.map { RecordedSessions.summary(of: $0.record) }
        for index in recorded.indices.reversed() where Self.needsDefaultTitle(recorded[index], liveIDs: liveIDs) {
            var record = entries[index].record
            let title = SessionDefaultTitle.make(
                for: record.facts, of: record.sessionId, in: record.workingDirectory,
                among: Self.merging(live: live, recorded: recorded))
            record.facts.title = title
            SessionIndexFile.saveLoggingFailure(record, in: entries[index].folder)
            recorded[index].title = title
        }
        return recorded
    }

    /// Tells whether a read gives a recorded session its default name: it is
    /// a root session, it is not live, and it has no title.
    ///
    /// - Parameters:
    ///   - summary: The recorded summary of the session.
    ///   - liveIDs: The ids of the live sessions.
    /// - Returns: `true` when the read names the session.
    private static func needsDefaultTitle(_ summary: SessionSummary, liveIDs: Set<ULID>) -> Bool {
        summary.kind == .root && summary.title == nil && !liveIDs.contains(summary.id)
    }

    /// The summary of a recorded session, made from its record, with the pin
    /// and the last use of the usage store.
    ///
    /// - Parameter record: The record of the session.
    /// - Returns: The summary. It is never live.
    private nonisolated func recordedSummary(of record: SessionRecord) -> SessionSummary {
        Self.withUsage(RecordedSessions.summary(of: record), currentUsageStore()?.usage(of: record.sessionId))
    }

    /// A summary with the pin and the last use of a usage.
    ///
    /// - Parameters:
    ///   - summary: The summary of a session.
    ///   - usage: The usage of the session, or `nil` for no pin and no use.
    /// - Returns: `summary` with ``SessionSummary/pinnedAt`` and
    ///   ``SessionSummary/lastUsedAt`` of `usage`.
    private static func withUsage(_ summary: SessionSummary, _ usage: SessionUsage?) -> SessionSummary {
        var summary = summary
        summary.pinnedAt = usage?.pinnedAt
        summary.lastUsedAt = usage?.lastUsedAt
        return summary
    }

    /// Lists the session folders of a recording root and returns the
    /// ``SessionRecord`` decoded from the `index.md` of each folder: the one
    /// file a listing reads. A host calls it with no router, for example for
    /// the ACP `session/list`, `session/delete` and `session/resume`, and for
    /// snapshots.
    ///
    /// Each folder named by a ULID that holds an `index.md` is a session; a
    /// folder with no `index.md` is not, and is left out. Router filters
    /// nothing more: a listing for a client can leave out each record whose
    /// ``SessionRecord/firstActivityAt`` is `nil`, a session that had no
    /// prompt.
    ///
    /// - Parameter recordingRoot: A recording root: the folder that holds the
    ///   session folders.
    /// - Returns: One record for each session, newest first
    ///   (``SessionRecord/sessionId`` descending), or none when the root does
    ///   not exist.
    /// - Throws: The error of the listing of a root that exists, or the read
    ///   error of an `index.md` that exists: ``SessionIndexFileError`` when it
    ///   holds no frontmatter or the frontmatter does not decode, or a
    ///   recording schema error when the record is from a newer router.
    public static func recordedSessions(in recordingRoot: URL) throws -> [SessionRecord] {
        try RecordedSessions(roots: [recordingRoot]).records()
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
    /// hold the recording folders of its root sessions. Router reads no
    /// setting of the host to find them. A query with `includesRecorded`, and
    /// ``summary(of:)`` for an id with no live session, read the roots again
    /// each time, so a root the host adds later is found. A later call
    /// replaces the roots.
    ///
    /// - Parameter roots: Gives the recording roots of the host.
    public func useRecordingRoots(_ roots: @escaping @Sendable () async throws -> [URL]) {
        recordingRoots = roots
    }

    /// The recording roots of the host, then each recording root of the
    /// usage store (``SessionUsage/recordingRoot``) that the host does not
    /// give, in path order. So a recorded session that the store knows is
    /// found after a restart also when the host gives no root for it. Each
    /// read of the recorded sessions reads the roots through this call.
    ///
    /// - Returns: The recording roots.
    /// - Throws: The error of the recording roots of the host.
    private func allRecordingRoots() async throws -> [URL] {
        let hostRoots = try await recordingRoots()
        let storeRoots = usageStoreRecordingRoots().map(Self.comparablePath(of:))
        let addedRoots = Set(storeRoots).subtracting(hostRoots.map(Self.comparablePath(of:)))
        return hostRoots + addedRoots.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// The recording root of each usage in the usage store
    /// (``SessionUsage/recordingRoot``), with no `await`. A usage with no
    /// recording root gives none. ``allRecordingRoots()`` and
    /// ``recordedSummaries(besides:)`` read the roots of the store through
    /// this call.
    ///
    /// - Returns: The recording roots of the usage store, in no order. With
    ///   no usage store, none.
    private nonisolated func usageStoreRecordingRoots() -> [URL] {
        currentUsageStore()?.usages().values.compactMap(\.recordingRoot) ?? []
    }

    // MARK: - Usage store

    /// Gives the directory the store of the pin and the last use of each
    /// session (ROUTER-3, D186). ``setPinned(_:of:)`` and ``markUsed(_:)``
    /// write it, and each summary gets ``SessionSummary/pinnedAt`` and
    /// ``SessionSummary/lastUsedAt`` from it. The recording root of each
    /// usage joins the recording roots of the host, so a recorded session
    /// that the store knows is found after a restart. A later call replaces
    /// the store.
    ///
    /// The call reads the store one time before it keeps it, so the first
    /// read of a file store does not occur under the lock of the registry.
    ///
    /// - Parameter usageStore: The usage store of the host.
    public func use(usageStore: any SessionUsageStore) {
        _ = usageStore.usages()
        state.withLock { $0.usageStore = usageStore }
    }

    /// The usage store of ``use(usageStore:)``.
    ///
    /// - Returns: The store, or `nil` when the host gave none.
    private nonisolated func currentUsageStore() -> (any SessionUsageStore)? {
        state.withLock { $0.usageStore }
    }

    /// See `SessionDirectory.setPinned(_:of:)` (Pin Session and Unpin
    /// Session, D118). Writes the pin to the usage store with the recording
    /// root of the session (``changeUsage(of:_:)``), and sends one
    /// `factsChanged` when the pin changes. A pin of a pinned session keeps
    /// its first time and sends no event. A directory with no usage store
    /// changes nothing and sends no event, as the Extras default does.
    ///
    /// - Parameters:
    ///   - pinned: `true` to pin the session, `false` to unpin it.
    ///   - id: The session id.
    /// - Returns: The summary of the session with the new pin.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id; the error of the recording roots of
    ///   the host; the read error of the `index.md` of a recorded session; or
    ///   the write error of the store.
    @discardableResult
    public func setPinned(_ pinned: Bool, of id: ULID) async throws -> SessionSummary {
        try await changeUsage(of: id) { store, recordingRoot, time in
            try store.setPinned(pinned, of: id, recordingRoot: recordingRoot, at: time)
        }
    }

    /// See `SessionDirectory.markUsed(_:)` (D184). Writes the time of the use
    /// to the usage store with the recording root of the session
    /// (``changeUsage(of:_:)``), and sends one `factsChanged`. A directory
    /// with no usage store changes nothing and sends no event, as the Extras
    /// default does.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary of the session with the new time of the last
    ///   use.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id; the error of the recording roots of
    ///   the host; the read error of the `index.md` of a recorded session; or
    ///   the write error of the store.
    @discardableResult
    public func markUsed(_ id: ULID) async throws -> SessionSummary {
        try await changeUsage(of: id) { store, recordingRoot, time in
            try store.markUsed(id, recordingRoot: recordingRoot, at: time)
        }
    }

    /// Changes the usage of the session `id` in the usage store, and sends
    /// `factsChanged` with the new summary when the pin or the last use
    /// changed: the one path of ``setPinned(_:of:)`` and ``markUsed(_:)``.
    ///
    /// A live session sends its live summary and stamps the time of change
    /// of its entry (``recordFactsChange(of:)``). A recorded session sends
    /// its recorded summary; its `index.md` is not written.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: Writes the change to the store with the recording root of
    ///     the session (``usageTarget(of:)``) and the time of the call, and
    ///     gives the usage after the change.
    /// - Returns: The summary of the session after the change, or the summary
    ///   with no change when the directory has no usage store.
    /// - Throws: What ``usageTarget(of:)`` throws, or what `change` throws.
    private func changeUsage(
        of id: ULID, _ change: (any SessionUsageStore, URL?, Date) throws -> SessionUsage
    ) async throws -> SessionSummary {
        let target = try await usageTarget(of: id)
        guard let store = currentUsageStore() else { return target.summary }
        let usage = try change(store, target.recordingRoot, Date())
        guard usage.pinnedAt != target.summary.pinnedAt || usage.lastUsedAt != target.summary.lastUsedAt else {
            return target.summary
        }
        guard target.summary.isLive else {
            let changed = Self.withUsage(target.summary, usage)
            emit(.factsChanged(changed))
            return changed
        }
        recordFactsChange(of: id)
        return try requireLiveSummary(of: id)
    }

    /// The summary of the session `id` before a change of its usage, and the
    /// recording root to write with the change.
    ///
    /// A live root session that records durably gives the folder that holds
    /// its recording directory. A live subagent or fork gives `nil`, so the
    /// store keeps the root it holds: its folder can sit inside the folder of
    /// its parent, which is not a recording root. A memory-only session gives
    /// `nil` too. A recorded session that is not live gives the recording
    /// root that holds its folder.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary and the recording root.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id; the error of the recording roots of the
    ///   host; or the read error of the `index.md` of a recorded session.
    private func usageTarget(of id: ULID) async throws -> (summary: SessionSummary, recordingRoot: URL?) {
        if let session = session(id: id), let summary = liveSummary(of: id) {
            let folder = summary.kind == .root ? Self.ledgerDirectory(of: session) : nil
            return (summary, folder?.deletingLastPathComponent())
        }
        guard let folder = try await recordedFolder(of: id), let record = try SessionIndexFile.read(in: folder) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return (recordedSummary(of: record), folder.deletingLastPathComponent())
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

    /// Releases the launcher and each fork that the directory holds
    /// (``Registry/heldForks``), and ends each open stream of ``events()``.
    ///
    /// The directory holds the launcher, and the launcher makes surfaces that
    /// hold the directory, so the host calls this at shutdown to break that
    /// loop. A fork holds its profile, and the profile holds the directory,
    /// so the release of the forks breaks that loop too. A host that closes
    /// its sessions at shutdown finds each live fork with ``session(id:)``.
    /// After the call, ``start(_:)`` throws `noLauncher` until the next
    /// ``use(launcher:)``. The streams end after the lock is released,
    /// because the end of a stream takes the lock to leave the directory. The
    /// forks are released after the lock too, because the last release of a
    /// fork runs its `deinit`.
    public func shutdown() {
        launcher = nil
        let (openStreams, releasedForks) = state.withLock { registry in
            let releasedForks = registry.heldForks
            registry.heldForks = [:]
            return (registry.fanout.removeAll(), releasedForks)
        }
        for continuation in openStreams {
            continuation.finish()
        }
        withExtendedLifetime(releasedForks) {}
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
    ///   launcher, the error of the launcher, the refusal of the first
    ///   message, or `SessionDirectoryError.unknownSession` when the session closed
    ///   before `start` returns.
    public func start(_ request: SessionStartRequest) async throws -> SessionSummary {
        let session = try await launch(request)
        _ = try session.mail(
            mail(carrying: request.firstMessage, from: request.startedBy, inReplyTo: nil, userHeader: nil))
        guard let summary = try await summary(of: session.id) else {
            throw SessionDirectoryError.unknownSession(session.id)
        }
        return summary
    }

    /// Starts a new root session for `request` through the launcher, and
    /// makes it live with the facts of `request`. The caller puts the first
    /// message of `request` in its mail queue.
    ///
    /// - Parameter request: The start request.
    /// - Returns: The new session.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, or the error of the launcher.
    private func launch(_ request: SessionStartRequest) async throws -> any RoutedSession {
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        let session = try await launcher.launchRootSession(for: request)
        admit(session: session, startedFor: request)
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
    private func admit(session: any RoutedSession, startedFor request: SessionStartRequest) {
        guard isRegistered(session: session) else {
            Self.writeMissingFacts(of: request, to: session)
            register(session, kind: .root, parentID: nil, requestedByClient: request.requestedByClient)
            return
        }
        if Self.writeMissingFacts(of: request, to: session) {
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
        _ = try? changeLiveEntry(
            of: id, announcing: { registry, summary in registry.fanout.send(.factsChanged(summary)) })
    }

    /// Changes the live entry of the session `id` under the lock of the
    /// registry, and gives its new summary.
    ///
    /// In one hold of the lock, the call:
    /// 1. finds the entry and its session,
    /// 2. applies `change` to the registry and to a copy of the entry,
    /// 3. stamps the time of the change of the entry,
    /// 4. puts the entry back, but only when `change` did not take it off
    ///    the registry,
    /// 5. makes the summary of the session, which is not live when `change`
    ///    took the entry off,
    /// 6. gives that summary to `announce`, so an event that tells the
    ///    change goes out under the same lock.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: The change to the registry and to the entry. It can take
    ///     the entry off the registry.
    ///   - announce: The step that reads the new summary under the same
    ///     lock. It changes nothing by default.
    /// - Returns: The summary of the session, changed now.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live session
    ///   has the id.
    private nonisolated func changeLiveEntry(
        of id: ULID,
        _ change: (inout Registry, inout Entry) -> Void = { _, _ in },
        announcing announce: (inout Registry, SessionSummary) -> Void = { _, _ in }
    ) throws -> SessionSummary {
        try state.withLock { registry in
            guard var entry = registry.entries[id], let session = entry.session else {
                throw SessionDirectoryError.unknownSession(id)
            }
            change(&registry, &entry)
            entry.updatedAt = Date()
            let isLive = registry.entries[id] != nil
            if isLive {
                registry.entries[id] = entry
            }
            var summary = Self.summary(of: session, in: entry, usage: registry.usage(of: id))
            summary.isLive = isLive
            announce(&registry, summary)
            return summary
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
    @discardableResult
    private static func writeMissingFacts(
        of request: SessionStartRequest, to session: any RoutedSession
    ) -> Bool {
        var completed = session.facts
        complete(facts: &completed, with: request)
        guard completed != session.facts else { return false }
        guard let actor = session as? RoutedSessionActor else {
            assertionFailure("a launcher returned a session that lacks the facts of its request and cannot change them")
            logSession(
                .error,
                "a launcher returned a session that lacks the facts of its request and cannot change them; the facts stay as the session holds them",
                session: session.id)
            return false
        }
        actor.updateFacts { complete(facts: &$0, with: request) }
        return true
    }

    /// Adds each fact of `request` that `facts` lacks: the tags of the
    /// request join the tags, and `startedBy` and the origin of the request
    /// fill a fact that is `nil`. A fact that `facts` holds stays.
    ///
    /// The title of the request is the one exception: it replaces the title
    /// of `facts`. The session is new, thus its title is the title of the
    /// request or the default name that its registration gave
    /// (``giveDefaultTitle(to:kind:parentID:)``), and a request with a title
    /// keeps its title. A request with no title, or with an empty title, keeps the
    /// default name (``SessionDefaultTitle/given(_:)``).
    ///
    /// - Parameters:
    ///   - facts: The facts of a session.
    ///   - request: The start request of the session.
    private static func complete(facts: inout SessionFacts, with request: SessionStartRequest) {
        facts.tags.formUnion(request.tags)
        facts.title = SessionDefaultTitle.given(request.title) ?? facts.title
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
    /// message. A sender that is not live
    /// gets a header with its id and `inReplyTo` only. The directory writes
    /// the header first for each message, so a header that the sender writes
    /// in its text stays in the fenced text.
    ///
    /// The prompt of a user message that names its source session starts
    /// with `userHeader` (``UserMessageHeader``, D199 (f)). The message stays
    /// a user message, with no notice. A user message with no source session
    /// is only the text.
    ///
    /// - Parameters:
    ///   - id: The id of the mail. The default is a new id.
    ///   - text: The text of the message.
    ///   - sender: The session that sends the message, or `nil` for a user.
    ///   - inReplyTo: The id of the message that this message answers, or
    ///     `nil`.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`. A message from a session does not use it.
    /// - Returns: The mail.
    private nonisolated func mail(
        id: MailID = MailID(), carrying text: String, from sender: ULID?, inReplyTo: MailID?,
        userHeader: UserMessageHeader?
    ) -> Mail {
        guard let sender else {
            let prompt = userHeader?.prompt(with: text) ?? text
            return Mail(id: id, sender: .user, body: .userMessage(prompt: prompt, options: UserMessageOptions()))
        }
        let header = AgentMessageHeader(sender: sender, summary: liveSummary(of: sender), inReplyTo: inReplyTo)
        let content = AgentMessageContent(header: header, text: text).encoded
        return Mail(id: id, sender: .session(sender), body: .agentMessage(from: sender, content: content))
    }

    // MARK: - Fork

    /// See `SessionDirectory.fork(_:)` (D205). Makes a live fork of the
    /// source at the cut of `request`, registers it as a `fork` of the
    /// source, and mails its first prompt. The steps come in this order:
    ///
    /// 1. The source maps the cut to a position in its history
    ///    (``RoutedSessionActor/prepareFork(at:)``), and the directory chooses
    ///    the id of the fork.
    /// 2. The launcher of the host builds the fork with its surface
    ///    (``SessionLauncher/forkSession(_:)``). A launcher that does not
    ///    implement that operation, and a directory with no launcher, build
    ///    the fork with the tools of the source. The fork has the id and the
    ///    cut of step 1, so its recording node and its
    ///    `forkedAtHistoryOrdinal` agree with the request of the launcher.
    /// 3. The directory registers the fork and holds it.
    /// 4. The directory mails the first prompt.
    ///
    /// So no prompt of the fork runs before the host gave its surface, and
    /// the host holds the fork from its start: it does not stop and restore
    /// the fork to give it its surface. When the launcher throws, or gives
    /// another session than the fork of its request, the fork is refused:
    /// the directory registers nothing, closes a fork that the request
    /// built, and removes its recording node.
    ///
    /// - The source must be live, or recorded and not archived. A recorded
    ///   source that is not live is restored first, through the launcher
    ///   (``SessionLauncher/restoreSession(id:)``), and the fork comes from the
    ///   restored session. This is the simpler path: a fork needs the tools
    ///   of its source, and only the host can make them.
    /// - The fork has the agent, the model profile, the slot, the
    ///   instructions and the settings of the source, the tools that the
    ///   launcher gave (or the tools of the source), and the
    ///   history of the source up to the cut (``ForkCutHistory``). Its record
    ///   holds `forkParentId` and `forkedAtHistoryOrdinal`, and it records as
    ///   a fork node in the recording folder of the source, so a restore of
    ///   the source restores the fork with its prefix.
    /// - The fork is a top-level session in the folder of its source: kind
    ///   `fork`, the source as its parent, origin `fork`. It is no subagent,
    ///   so it is not in ``unendedChildren(of:)`` of the source, and the end,
    ///   the close or the archive of the source does not end it. The
    ///   directory holds it until it leaves the live list
    ///   (``Registry/heldForks``).
    /// - Its default name is the name of the source with `-fork`
    ///   (`SessionName.fork(sourceName:usedNames:)`), among the sessions of
    ///   the folder that are not archived. Its `started` event holds the name
    ///   and the client of `request`.
    /// - The first prompt of `request`, when it is not `nil`, waits in the
    ///   mail queue of the fork as a user message, after the registration,
    ///   as the first message of ``start(_:)`` does. It starts the first turn
    ///   of the fork.
    ///
    /// The forker of `request` goes to the log, for the audit. It is not a
    /// fact of the fork. The KV cache of the source is not reused.
    ///
    /// - Parameter request: The source, the cut, the first prompt, the
    ///   client and the forker.
    /// - Returns: The summary of the fork.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the source id, or when the fork closed before
    ///   the call returns; `SessionDirectoryError.archivedSession` for an
    ///   archived source; `SessionDirectoryError.noLauncher` for a recorded
    ///   source when the directory has no launcher; the error of the restore;
    ///   `SessionDirectoryError.forkUnsupported` for a source that records
    ///   nothing durably; `SessionDirectoryError.forkCutOutOfRange` for a cut
    ///   outside the history; the error of the read of the recording; the
    ///   error of the launcher or of the build of the fork;
    ///   ``SessionLaunchForkError`` for a launcher that builds the fork two
    ///   times or gives another session; or the refusal of the first prompt.
    public func fork(_ request: SessionForkRequest) async throws -> SessionSummary {
        let source = try await forkSource(of: request.sourceID)
        let owner = try Self.recordOwner(of: source)
        let fork = try await launchFork(
            SessionLaunchForkRequest(
                source: owner, seed: try await owner.prepareFork(at: request.cut), forkID: ULID.generate(),
                requestedByClient: request.requestedByClient))
        register(
            fork, kind: .fork, parentID: source.id, requestedByClient: request.requestedByClient, namingFork: true)
        state.withLock { $0.heldForks[fork.id] = fork }
        Self.logSession(
            .info, "a session forked", session: source.id,
            metadata: [
                RouterTelemetry.LogMetadataKey.forkSessionId: "\(fork.id.description)",
                RouterTelemetry.LogMetadataKey.forker: "\(request.forker)",
            ])
        if let firstPrompt = request.firstPrompt {
            _ = try fork.mail(mail(carrying: firstPrompt, from: nil, inReplyTo: nil, userHeader: nil))
        }
        guard let summary = liveSummary(of: fork.id) else {
            throw SessionDirectoryError.unknownSession(fork.id)
        }
        return summary
    }

    /// Builds the fork of `request`: through the launcher of the host
    /// (``SessionLauncher/forkSession(_:)``) when the directory has one,
    /// else with the tools of the source. The fork must be the fork that
    /// `request` built.
    ///
    /// When the launcher returns or throws, the build of `request` closes
    /// (``ForkBuild/close()``), so the request builds no fork after this
    /// call. When the build or the launcher throws, or the launcher gives
    /// another session, the fork is refused: a fork that `request` built is
    /// closed, and its recording node is removed.
    ///
    /// - Parameter request: The fork request.
    /// - Returns: The fork, not registered.
    /// - Throws: The error of the launcher or of the build;
    ///   ``SessionLaunchForkError/notTheRequestedFork(_:)`` when the launcher
    ///   gives another session.
    private func launchFork(_ request: SessionLaunchForkRequest) async throws -> RoutedSessionActor {
        let session: any RoutedSession
        do {
            session = if let launcher { try await launcher.forkSession(request) } else { try await request.makeFork() }
        } catch {
            await discardRefusedFork(request.build.close(), of: request)
            throw error
        }
        let built = request.build.close()
        guard let built, built === session else {
            await discardRefusedFork(built, of: request)
            throw SessionLaunchForkError.notTheRequestedFork(request.forkID)
        }
        return built
    }

    /// Removes `fork`, the fork of a refused `request`
    /// (``ForkBuild/discard(_:)``). A recording node that stays is logged:
    /// the refusal of the fork stands.
    ///
    /// - Parameters:
    ///   - fork: The fork that `request` built, or `nil` when it built none.
    ///   - request: The refused fork request.
    private func discardRefusedFork(_ fork: RoutedSessionActor?, of request: SessionLaunchForkRequest) async {
        guard let fork else { return }
        do {
            try await request.build.discard(fork)
        } catch {
            Self.logSession(
                .error, "the recording node of a refused fork stays; its removal failed", session: request.forkID,
                error: error)
        }
    }

    /// The live session that a fork of `id` comes from: the live session,
    /// or the recorded session that the launcher restores.
    ///
    /// - Parameter id: The id of the source.
    /// - Returns: The live source.
    /// - Throws: What ``fork(_:)`` throws for the source.
    private func forkSource(of id: ULID) async throws -> any RoutedSession {
        if let live = session(id: id) {
            guard live.facts.archivedAt == nil else { throw SessionDirectoryError.archivedSession(id) }
            return live
        }
        guard let recorded = try await summary(of: id) else { throw SessionDirectoryError.unknownSession(id) }
        guard recorded.state != .archived else { throw SessionDirectoryError.archivedSession(id) }
        guard let launcher else { throw SessionDirectoryError.noLauncher }
        return try await launcher.restoreSession(id: id)
    }

    // MARK: - Messages

    /// See `SessionDirectory.send(_:)`. Resolves the address
    /// (``FoundationModelsExtras/SessionAddress/resolution(from:among:recordedSummary:)``)
    /// and acts on the decision:
    ///
    /// - Each live target gets the message as a `Mail` in its own mail queue,
    ///   with the sender in its transcript (``deliver(_:chainDepth:userHeader:to:)``). A
    ///   durable target gets a message from a session through a file in its
    ///   `inbox/` folder, and the scan of the inbox puts the mail in the
    ///   queue. A message from a user sender (a UI send) goes to the queue at
    ///   once, with no file, and the ledger keeps the client id. The receipt
    ///   follows the delivery rules of ROUTER-5: `delivered` for an idle
    ///   target, whose mail starts a turn, and `queued` for a working target
    ///   or one that needs input, whose mail waits in its queue for the end
    ///   of the turn. The session's pump then carries every waiting message
    ///   in one turn. No delivery waits for a free slot: the number of
    ///   sessions that work at the same time has no limit (D72).
    /// - A recorded target that is not live gets a message from a session,
    ///   and a message from a user sender that names its source session, as
    ///   a file in its `inbox/` folder, and nothing more
    ///   (``sendToRecorded(_:chainDepth:userHeader:isArchived:to:)``). A message from a
    ///   user sender with no source session is a `refused` receipt with
    ///   ``userNeedsLiveSessionReason`` and no file.
    ///   The directory does not restore the session and does not call the
    ///   launcher. The receipt is `sent`: the message is written where the
    ///   target reads it, and it is not in a queue. When a host opens the
    ///   session, the first scan of its inbox watcher delivers the file, and
    ///   the `messageDelivered` event follows.
    /// - An agent address always gets a new root session through the
    ///   launcher (D199 (e)), also when a session of the agent is live, with
    ///   origin `message` and the message as its first message, and the
    ///   receipt is `started`
    ///   (``startAgent(_:in:for:chainDepth:userHeader:)``).
    /// - An archived target, live or not, gets the message as a file in its
    ///   `inbox/` folder, as a recorded target does, and the session stays
    ///   archived (D204). The receipt is `sent` with the note
    ///   ``archivedNote`` in its reason, and the directory sends
    ///   `messageQueued`. A message from a user sender with no source session
    ///   gets the file too, as the FoundationModelsExtras contract says for
    ///   an archived target: the archive is not final, so the message must
    ///   not be lost. The message starts no turn: the scan of the inbox does
    ///   not deliver a file to an archived session (``scanInbox(of:)``), and
    ///   ``unarchive(_:by:)`` of a live session scans its inbox.
    /// - A refusal of the resolver is a `refused` receipt with its reason
    ///   and target.
    ///
    /// The loop guards of ``SessionMessageLimits`` apply to each sender
    /// (ROUTER-5). A text longer than the limit throws before the address is
    /// resolved. After the resolve, a send of a turn after the most sends of
    /// one turn (``countSend(from:in:)``), or a send above the deepest chain
    /// (``chainDepth(of:in:)``), is one `refused` receipt with no target. A
    /// tag send delivers to its first targets up to the limit, and each other
    /// target gets a `refused` receipt (``deliver(_:chainDepth:userHeader:toEach:)``).
    ///
    /// A message from a user sender that names its source session
    /// (``FoundationModelsExtras/OutgoingSessionMessage/sourceSession``) stays
    /// a user message, and its prompt starts with a header that names the
    /// source session (``UserMessageHeader``, D199 (f)): its title and its
    /// folder from its live summary, else from its recorded summary. The
    /// delivered message keeps the source session. A message from a user
    /// sender with no source session gets no header. A recorded target gets
    /// the header that the send makes: the file keeps the header line, and
    /// the scan of the inbox at the next open starts the prompt with it. The
    /// title and the folder in the header are thus the ones at the time of
    /// the send.
    ///
    /// The turn of a session sender is the origin of the work that runs the
    /// send (``OriginContext/current``), read before the first `await`. The
    /// sender's tool call makes the send inside its turn, so its origin is in
    /// scope here, also for the first tool call of the turn, before the event
    /// feed of the directory has seen that turn.
    ///
    /// Each delivered message goes into the ledger of its target
    /// (``SessionMessageLedger``) with its chain depth when its mail goes in
    /// the queue. Its one `messageDelivered` event (D199 (f)) comes when the
    /// target gets the message: when the pump of the target takes the mail,
    /// before the first output of that answer (``sendWhenDelivered(_:userHeader:to:)``).
    /// Thus a message to an idle target gives its event when its turn
    /// starts, and a message to a working target when the turn ends. A
    /// message that ``inbox(of:markRead:)`` reads while its mail waits gives
    /// its event at the read, and a mail that is cancelled before the take
    /// gives no event. For a durable target and a
    /// sender that is a session, the ledger is written at the scan of the
    /// inbox file, after the receipt: until the
    /// `messageDelivered` event, ``inbox(of:markRead:)`` and
    /// ``withdrawWaitingMail(_:from:)`` can miss the `messageID` of the
    /// receipt. A target that is closing but still registered gives
    /// `delivered`, and its file waits for the next open of the session. The
    /// old `refused` receipt as not live is gone for that case.
    ///
    /// - Parameter message: The sender, the address, the text and the reply
    ///   id of the message.
    /// - Returns: One receipt for each target session.
    /// - Throws: `SessionDirectoryError.messageTooLong(limit:)` for a text
    ///   longer than the limit, `SessionDirectoryError.unknownSession` for a
    ///   session sender or a session id target that no live or recorded
    ///   session has, `SessionDirectoryError.noLauncher` when an agent
    ///   address must start a session with no launcher, the start errors of
    ///   the launcher for an agent
    ///   address, `JSONLFileError.readFailed(description:)` when the
    ///   `messages.jsonl` of a target or of the sender exists and does not
    ///   read, or the error of the recording roots of the host.
    public func send(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        let turn = OriginContext.current
        guard message.text.utf8.count <= limits.maxMessageBytes else {
            throw SessionDirectoryError.messageTooLong(limit: limits.maxMessageBytes)
        }
        let recorded = try await recordedSummaries()
        let live = liveSummaries()
        let resolution = try message.to.resolution(from: message.from, among: live) { id in
            recorded.first { $0.id == id }
        }
        let chainDepth = try await chainDepth(of: message.from, in: turn)
        if let refusal = countSend(from: message.from, in: turn) ?? refusal(ofChainDepth: chainDepth) {
            return [SessionSendReceipt(outcome: .refused, reason: refusal)]
        }
        let userHeader = userHeader(of: message, recorded: recorded)
        switch resolution {
        case .deliver(let targets):
            return try deliver(message, chainDepth: chainDepth, userHeader: userHeader, toEach: targets)
        case .sendToRecorded(let id):
            let isArchived = (live.first { $0.id == id } ?? recorded.first { $0.id == id })?.state == .archived
            return [
                try await sendToRecorded(
                    message, chainDepth: chainDepth, userHeader: userHeader, isArchived: isArchived, to: id)
            ]
        case .startAgent(let agentID, let folder):
            return [
                try await startAgent(agentID, in: folder, for: message, chainDepth: chainDepth, userHeader: userHeader)
            ]
        case .refused(let reason, let target):
            return [SessionSendReceipt(target: target, outcome: .refused, reason: reason)]
        }
    }

    /// The header of a message from a user sender that names its source
    /// session (``UserMessageHeader``, D199 (f)), with the title and the
    /// folder of the live summary of the source session, else of its
    /// recorded summary.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - recorded: The summaries of the recorded sessions.
    /// - Returns: The header, or `nil` for a message from a session or a
    ///   message with no source session.
    private nonisolated func userHeader(
        of message: OutgoingSessionMessage, recorded: [SessionSummary]
    ) -> UserMessageHeader? {
        guard case .user = message.from, let source = message.sourceSession else { return nil }
        let summary = liveSummary(of: source) ?? recorded.first { $0.id == source }
        return UserMessageHeader(source: source, summary: summary)
    }

    /// The chain depth of a message that `sender` sends in `turn`: one more
    /// than the deepest message of the turn, by the ledger of the sender. The
    /// mail ids of the turn are the ids of the messages the turn answers, and
    /// the ledger of the sender holds each message the directory delivered
    /// to it.
    ///
    /// A UI sender, a sender outside a turn, and a turn that no directory
    /// message started (a user turn) give ``firstChainDepth``.
    ///
    /// - Parameters:
    ///   - sender: The sender of the message.
    ///   - turn: The origin of the work that runs the send.
    /// - Returns: The chain depth.
    /// - Throws: The error of a read of the ledger of the sender, or the
    ///   error of the recording roots of the host.
    private func chainDepth(of sender: SessionMessageSender, in turn: Origin) async throws -> Int {
        guard let id = sender.sessionID, case .mail(let mailIDs) = turn,
            let ledger = try await knownLedger(of: id)
        else { return Self.firstChainDepth }
        let turnDepth = mailIDs.compactMap { ledger.message($0)?.chainDepth }.max()
        return turnDepth.map { $0 + 1 } ?? Self.firstChainDepth
    }

    /// Counts a send of `sender` in `turn`, for the guard of
    /// ``SessionMessageLimits/maxSendsPerTurn``.
    ///
    /// The count is keyed by the mail ids of the turn: a turn that shares no
    /// mail id with the last counted turn of the sender is a new turn, and
    /// starts a new count. A mail that joins the running turn adds its id to
    /// the origin of the turn, so the turn keeps its count. A UI sender and a
    /// sender outside a turn have no turn, so this guard does not apply to
    /// them.
    ///
    /// - Parameters:
    ///   - sender: The sender of the message.
    ///   - turn: The origin of the work that runs the send.
    /// - Returns: The reason of the refusal when the turn already made the
    ///   most sends, else `nil` after the send is counted.
    private func countSend(from sender: SessionMessageSender, in turn: Origin) -> String? {
        guard let id = sender.sessionID, case .mail(let mailIDs) = turn else { return nil }
        let sameTurn = turnSends[id].flatMap { $0.mailIDs.isDisjoint(with: mailIDs) ? nil : $0 }
        var sends = sameTurn ?? TurnSends(mailIDs: [], count: 0)
        guard sends.count < limits.maxSendsPerTurn else { return limits.tooManySendsReason }
        sends.mailIDs.formUnion(mailIDs)
        sends.count += 1
        turnSends[id] = sends
        return nil
    }

    /// The refusal of a message of `chainDepth`.
    ///
    /// - Parameter chainDepth: The chain depth of a message.
    /// - Returns: The reason of the refusal above
    ///   ``SessionMessageLimits/maxChainDepth``, else `nil`.
    private func refusal(ofChainDepth chainDepth: Int) -> String? {
        chainDepth > limits.maxChainDepth ? limits.chainTooDeepReason : nil
    }

    /// Delivers `message` to each live session of `targets`, in order, up to
    /// ``SessionMessageLimits/maxTagTargets``; each other target gets a
    /// `refused` receipt with the reason of the limit. Only a tag address
    /// resolves to more than one target.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - targets: The session ids of the live targets, in order.
    /// - Returns: One receipt for each target, in the order of `targets`.
    /// - Throws: The errors of ``deliver(_:chainDepth:userHeader:to:)``.
    private func deliver(
        _ message: OutgoingSessionMessage, chainDepth: Int, userHeader: UserMessageHeader?, toEach targets: [ULID]
    ) throws -> [SessionSendReceipt] {
        let delivered = try targets.prefix(limits.maxTagTargets).map {
            try deliver(message, chainDepth: chainDepth, userHeader: userHeader, to: $0)
        }
        let refused = targets.dropFirst(limits.maxTagTargets).map {
            SessionSendReceipt(target: $0, outcome: .refused, reason: limits.tooManyTargetsReason)
        }
        return delivered + refused
    }

    /// Delivers `message` to the live session `id`.
    ///
    /// A message from a session to a durable session goes as a file in its
    /// `inbox/` folder (``SessionInboxFile``), the same way as a file that a
    /// person writes. The scan of the inbox (``scanInbox(of:)``) puts the mail in the mail
    /// queue of the session, and keeps the message in the ledger. The
    /// receipt can thus come before the ledger holds the message:
    /// ``inbox(of:markRead:)`` and ``withdrawWaitingMail(_:from:)`` can miss
    /// the `messageID` of the receipt for a short time, until the scan. The
    /// `messageDelivered` event comes after the scan, when the pump takes
    /// the mail. A session that is closing but still
    /// registered also gets `delivered`: the file waits in its inbox for the
    /// next open of the session. This is not a `refused` receipt as not live.
    ///
    /// A durable session whose inbox watcher did not open
    /// (``hasNoInboxWatcher(_:)``) has no other reader of the file, so the
    /// send calls ``scanInbox(of:)`` right after the write, and the
    /// message is in the ledger when the receipt returns.
    ///
    /// A message from a user sender (a UI send) takes the direct path
    /// (``deliverDirectly(_:chainDepth:userHeader:to:outcome:)``) to a live session, a
    /// durable one too: the mail goes in the queue of the session and the
    /// message in the ledger at once (``hand(_:userHeader:to:ledger:isQueued:)``), so
    /// the receipt can tell `delivered` from `queued`. A memory-only
    /// session has no folder, so each message to it takes the direct path.
    /// A session on the direct path that closed and takes no more mail is
    /// refused as not live.
    ///
    /// The mail goes into the queue of the session in each state (the
    /// decision of the user on ROUTER-5), and the receipt tells which rule
    /// applied (``deliveryOutcome(of:)``): `delivered` when the session was
    /// idle, so the mail starts a turn, else `queued`, because the mail
    /// waits for the end of the turn that runs. A session that left the
    /// directory since the resolve is refused as not live.
    ///
    /// A `queued` receipt gives `messageQueued` before the send returns: on
    /// the inbox path after the write of the file (``sendQueued(_:to:)``),
    /// and on the direct path after the put
    /// (``hand(_:userHeader:to:ledger:isQueued:)``). A `delivered` receipt
    /// gives none.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - id: The session id of a live target.
    /// - Returns: The `delivered` or `queued` receipt, or a `refused`
    ///   receipt as not live.
    /// - Throws: ``SessionInboxFileError`` or the error of the write of the
    ///   inbox file of a durable session, or the error of a read of the
    ///   ledger of a session on the direct path, or a refusal of its mail
    ///   other than a closed session.
    private func deliver(
        _ message: OutgoingSessionMessage, chainDepth: Int, userHeader: UserMessageHeader?, to id: ULID
    ) throws -> SessionSendReceipt {
        guard let session = session(id: id), let outcome = deliveryOutcome(of: id) else {
            return SessionSendReceipt(target: id, outcome: .refused, reason: Self.notLiveReason)
        }
        guard message.from.sessionID != nil, let folder = Self.ledgerDirectory(of: session) else {
            return try deliverDirectly(
                message, chainDepth: chainDepth, userHeader: userHeader, to: session, outcome: outcome)
        }
        let file = try writeInboxFile(message, chainDepth: chainDepth, userHeader: nil, to: folder)
        if outcome == .queued {
            sendQueued(file, to: id)
        }
        if hasNoInboxWatcher(id) {
            scanInbox(of: id)
        }
        return SessionSendReceipt(messageID: file.id, target: id, outcome: outcome)
    }

    /// Whether the registry holds a durable session that has no inbox
    /// watcher, because the inbox folder did not open at the registration.
    /// Nothing else delivers a file of such a session, so ``deliver(_:chainDepth:userHeader:to:)``
    /// scans the inbox itself.
    ///
    /// - Parameter id: The session id.
    /// - Returns: `true` when the entry of `id` has no watcher. A memory-only
    ///   session has no watcher too, but it never reaches this check: it has
    ///   no inbox folder.
    private nonisolated func hasNoInboxWatcher(_ id: ULID) -> Bool {
        state.withLock { $0.entries[id]?.inboxWatcher == nil }
    }

    /// Delivers `message` to the live session `session` with no inbox file:
    /// puts its mail in the mail queue of the session, and keeps it in the
    /// ledger (``hand(_:userHeader:to:ledger:isQueued:)``). This is the path of each message
    /// to a memory-only session, which has no inbox folder, and of a message
    /// from a user sender to a live durable session.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - session: The live target.
    ///   - outcome: The outcome of the receipt (``deliveryOutcome(of:)``).
    /// - Returns: The receipt with `outcome`, or a `refused` receipt as not
    ///   live for a session that closed and takes no more mail.
    /// - Throws: The error of a read of the ledger of the session, or a
    ///   refusal of the mail other than a closed session.
    private func deliverDirectly(
        _ message: OutgoingSessionMessage, chainDepth: Int, userHeader: UserMessageHeader?,
        to session: any RoutedSession, outcome: SessionSendReceipt.Outcome
    ) throws -> SessionSendReceipt {
        let ledger = try ledger(of: session.id, in: Self.ledgerDirectory(of: session))
        let delivered = Self.delivered(message, chainDepth: chainDepth, to: session.id)
        do {
            try hand(delivered, userHeader: userHeader, to: session, ledger: ledger, isQueued: outcome == .queued)
        } catch MailRefusal.closed {
            return SessionSendReceipt(target: session.id, outcome: .refused, reason: Self.notLiveReason)
        }
        return SessionSendReceipt(messageID: delivered.id, target: session.id, outcome: outcome)
    }

    /// Writes `message` as a new file in the `inbox/` folder of a durable
    /// session. The file carries the sender, the reply id, the chain depth
    /// and the source session of the message, the header line of `userHeader`,
    /// and a new message id.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - folder: The session folder of the target.
    /// - Returns: The message of the file. Its id is also the name of the
    ///   file.
    /// - Throws: ``SessionInboxFileError`` when the file format refuses the
    ///   message, or the error of the write.
    private func writeInboxFile(
        _ message: OutgoingSessionMessage, chainDepth: Int, userHeader: UserMessageHeader?, to folder: URL
    ) throws -> SessionInboxMessage {
        let file = SessionInboxMessage(
            id: MailID(), from: message.from, inReplyTo: message.inReplyTo, chainDepth: chainDepth,
            text: message.text, sourceSession: message.sourceSession, userHeader: userHeader?.line)
        try SessionInboxFile.write(file, to: folder, maxMessageBytes: limits.maxMessageBytes)
        return file
    }

    /// Sends the `messageQueued` event of the inbox file `file` of the
    /// session `id`: the target did not take the message yet. The send
    /// calls this after the write of the file and before it returns its
    /// receipt.
    ///
    /// The file of a live target waits for the scan of the inbox, which runs
    /// on this actor. The send has no suspension point between the write and
    /// this event, so the event comes before the scan and before the
    /// `messageDelivered` event of the take. The time of the message in
    /// the event is the time of the send. The scan gives the message the
    /// time of the scan (``delivered(_:to:)``).
    ///
    /// - Parameters:
    ///   - file: The message of the inbox file.
    ///   - id: The session id of the target.
    private nonisolated func sendQueued(_ file: SessionInboxMessage, to id: ULID) {
        emit(.messageQueued(Self.delivered(file, to: id)))
    }

    /// Puts the mail of `delivered` in the mail queue of `session`, and then
    /// keeps `delivered` in `ledger`. This is the one step that each delivery
    /// shares: ``deliverDirectly(_:chainDepth:userHeader:to:outcome:)``,
    /// ``scanInbox(of:)`` and ``startAgent(_:in:for:chainDepth:userHeader:)``
    /// all end here. The step has no suspension point, so no other work of
    /// the directory runs between the mail and the ledger.
    ///
    /// The `messageDelivered` event of `delivered` waits for the delivery
    /// (``sendWhenDelivered(_:userHeader:to:)``): the step sets it up before the put,
    /// because the pump of the session can take the mail at once. A refused
    /// mail takes it down again, with no event.
    ///
    /// A message of a `queued` receipt (`isQueued`) also gives the
    /// `messageQueued` event, after the ledger keeps it and before the send
    /// returns. The step sets it up before the put too
    /// (``Registry/awaitingQueuedEvent``), so a pump that takes the mail at
    /// once sends it before `messageDelivered`. A refused mail gives no
    /// event (``Registry/forgetRefusedMail(_:)``). A cancel or a loss of the
    /// mail after the put does not stop `messageQueued`: the send returns a
    /// `queued` receipt, so the event goes out.
    ///
    /// The header of the sender in the mail is built from the live summary
    /// of the sender (``mail(id:carrying:from:inReplyTo:userHeader:)``). A
    /// user message that names its source session gets `userHeader`.
    ///
    /// - Parameters:
    ///   - delivered: The message to deliver.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - session: The live target session of `delivered`.
    ///   - ledger: The ledger of the target. Nothing is kept in it when the
    ///     mail is refused.
    ///   - isQueued: `true` when the receipt of the send is `queued`, so the
    ///     step sends `messageQueued`. The default is `false`: a scan of an
    ///     inbox file and the first mail of a started session give no
    ///     `messageQueued` here.
    /// - Throws: The refusal of the mail, for example `MailRefusal.closed`
    ///   for a session that takes no more mail.
    private func hand(
        _ delivered: SessionMessage, userHeader: UserMessageHeader?, to session: any RoutedSession,
        ledger: SessionMessageLedger, isQueued: Bool = false
    ) throws {
        if isQueued {
            state.withLock { $0.awaitingQueuedEvent[delivered.id] = delivered }
        }
        let isObserved = sendWhenDelivered(delivered, userHeader: userHeader, to: session)
        do {
            _ = try session.mail(
                mail(
                    id: delivered.id, carrying: delivered.text, from: delivered.from.sessionID,
                    inReplyTo: delivered.inReplyTo, userHeader: userHeader))
        } catch {
            state.withLock { $0.forgetRefusedMail(delivered.id) }
            throw error
        }
        keep(delivered, in: ledger)
        state.withLock { $0.sendQueued(delivered.id) }
        if !isObserved {
            emit(.messageDelivered(delivered))
        }
    }

    /// Sets up the `messageDelivered` event of `delivered`: the message
    /// waits in ``Registry/awaitingDelivery`` until the target reports the
    /// fate of its mail (``sessionDidReport(_:)``). The event goes out when
    /// the pump of the target takes the mail, before the first output of
    /// that answer, or when ``inbox(of:markRead:)`` reads the message while
    /// its mail waits. A mail that ends with no delivery gives no event.
    ///
    /// Only a ``RoutedSessionActor`` reports the fate of its mail. Each
    /// session that a router vends is one, so another session is a surprise:
    /// the call stops a debug build and logs the surprise, and the caller
    /// sends the event when the mail is in the queue.
    ///
    /// - Parameters:
    ///   - delivered: The message to deliver.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`. An archive keeps it with the message.
    ///   - session: The live target of `delivered`.
    /// - Returns: `true` when the event waits for the delivery, `false` when
    ///   the caller sends it after the put.
    private nonisolated func sendWhenDelivered(
        _ delivered: SessionMessage, userHeader: UserMessageHeader?, to session: any RoutedSession
    ) -> Bool {
        guard session is RoutedSessionActor else {
            assertionFailure("a live session reports no fate of its mail")
            Self.logSession(
                .error,
                "a live session reports no fate of its mail; its messageDelivered event goes out when the mail is in the queue",
                session: session.id)
            return false
        }
        state.withLock {
            $0.awaitingDelivery[delivered.id] = AwaitedDelivery(message: delivered, userHeader: userHeader)
        }
        return true
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

    /// Writes `message` as a file in the `inbox/` folder of the recorded
    /// session `id`, which is not live, or of the archived session `id`, live
    /// or not, and stops. The directory restores nothing and does not call
    /// the launcher. The file waits until a host opens the session: the
    /// registration starts the watcher of the inbox, and the first scan of
    /// the watcher delivers the file (``scanInbox(of:)``), where its mail
    /// starts a turn.
    ///
    /// A message from a user sender (a UI send) that names its source
    /// session also goes to the file (D199 (f)). The file keeps the client
    /// id, the source session and the header line of `userHeader`, and the
    /// scan delivers it as a user message whose prompt starts with that line.
    /// A message from a user sender with no source session to a recorded
    /// session is refused: it needs a live session, which takes the direct
    /// path (``deliverDirectly(_:chainDepth:userHeader:to:outcome:)``).
    ///
    /// An archived target gets each message as a file, also a message from a
    /// user sender with no source session, and the receipt has the note
    /// ``archivedNote`` (D204). The session stays archived. The scan does not
    /// deliver a file to an archived session, also when a client opened it
    /// with `session/load`, so the file waits for the unarchive
    /// (``unarchive(_:by:)``). The file of a live archived session goes to
    /// the folder of the live session, and a recorded one to the folder that
    /// a recording root holds.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`.
    ///   - isArchived: True when the target is archived.
    ///   - id: The session id of the recorded or archived target.
    /// - Returns: The `sent` receipt, with the id of the message and the
    ///   target, and with the note ``archivedNote`` for an archived target:
    ///   the file is written, and the message is not in a queue. The
    ///   send gives `messageQueued` before it returns
    ///   (``sendQueued(_:to:)``), and the `messageDelivered` event reports
    ///   the delivery later. A `refused`
    ///   receipt with ``userNeedsLiveSessionReason`` for a user sender with
    ///   no source session to a recorded target that is not archived, and no
    ///   file.
    /// - Throws: `SessionDirectoryError.unknownSession(_:)` when the session
    ///   has no folder: no recording root holds the folder of a recorded
    ///   session, or a live archived session is memory-only. Or the errors of
    ///   ``writeInboxFile(_:chainDepth:userHeader:to:)``.
    private func sendToRecorded(
        _ message: OutgoingSessionMessage, chainDepth: Int, userHeader: UserMessageHeader?, isArchived: Bool,
        to id: ULID
    ) async throws -> SessionSendReceipt {
        guard isArchived || message.from.sessionID != nil || message.sourceSession != nil else {
            return SessionSendReceipt(target: id, outcome: .refused, reason: Self.userNeedsLiveSessionReason)
        }
        guard let folder = try await inboxFolder(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        let file = try writeInboxFile(message, chainDepth: chainDepth, userHeader: userHeader, to: folder)
        sendQueued(file, to: id)
        return SessionSendReceipt(
            messageID: file.id, target: id, outcome: .sent, reason: isArchived ? Self.archivedNote : nil)
    }

    /// The session folder that holds the `inbox/` folder of the session
    /// `id`: the recording directory of a live durable session, else the
    /// folder that a recording root holds (``recordedFolder(of:)``).
    ///
    /// - Parameter id: The session id.
    /// - Returns: The folder, or `nil` when the session has none.
    /// - Throws: The error of the recording roots of the host.
    private func inboxFolder(of id: ULID) async throws -> URL? {
        if let live = session(id: id), let folder = Self.ledgerDirectory(of: live) {
            return folder
        }
        return try await recordedFolder(of: id)
    }

    /// Starts a new root session of the agent through the launcher, and
    /// hands it `message` as its first message
    /// (``hand(_:userHeader:to:ledger:isQueued:)``): the ledger of the new session
    /// keeps the message, and `messageDelivered` goes out when the pump of
    /// the session takes it.
    ///
    /// - Parameters:
    ///   - agentID: The agent of the address.
    ///   - folder: The folder of the address, else the folder of the sender
    ///     session, or `nil` for a user sender with no folder.
    ///   - message: The message.
    ///   - chainDepth: The chain depth of the message.
    ///   - userHeader: The header of a user message that names its source
    ///     session, or `nil`. The first mail of the new session starts with
    ///     it.
    /// - Returns: The `started` receipt, with the new session as its target.
    /// - Throws: `SessionDirectoryError.noLauncher` when the directory has no
    ///   launcher, the error of the launcher, the refusal of the first mail,
    ///   or the error of a read of the ledger of the new session.
    private func startAgent(
        _ agentID: String, in folder: URL?, for message: OutgoingSessionMessage, chainDepth: Int,
        userHeader: UserMessageHeader?
    ) async throws -> SessionSendReceipt {
        let request = SessionStartRequest(
            agentID: agentID, workingDirectory: folder, firstMessage: message.text,
            startedBy: message.from.sessionID, origin: .message)
        let session = try await launch(request)
        let delivered = Self.delivered(message, chainDepth: chainDepth, to: session.id)
        try hand(
            delivered, userHeader: userHeader, to: session,
            ledger: try ledger(of: session.id, in: Self.ledgerDirectory(of: session)))
        return SessionSendReceipt(messageID: delivered.id, target: session.id, outcome: .started)
    }

    /// The record of `message` as the directory delivers it to `target` now.
    ///
    /// - Parameters:
    ///   - message: The message.
    ///   - id: The id of the mail that carries it. The default is a new id.
    ///   - chainDepth: The chain depth of the message.
    ///   - target: The session id of the target.
    /// - Returns: The delivered message, not read, with `chainDepth` and the
    ///   source session of `message`, sent now at the precision of the ledger
    ///   (``SessionMessageLedger/recordedInstant(of:)``), so the message a
    ///   restore reads back equals the one delivered.
    private static func delivered(
        _ message: OutgoingSessionMessage, id: MailID = MailID(), chainDepth: Int, to target: ULID
    ) -> SessionMessage {
        SessionMessage(
            id: id, from: message.from, to: target, text: message.text, inReplyTo: message.inReplyTo,
            sourceSession: message.sourceSession, sentAt: SessionMessageLedger.recordedInstant(of: Date()),
            chainDepth: chainDepth)
    }

    /// Records `delivered` in `ledger`, the ledger of its target, and holds
    /// the ledger.
    ///
    /// - Parameters:
    ///   - delivered: The delivered message.
    ///   - ledger: The ledger of the target of `delivered`.
    private func keep(_ delivered: SessionMessage, in ledger: SessionMessageLedger) {
        var ledger = ledger
        ledger.record(delivered)
        ledgers[delivered.to] = ledger
    }

    // MARK: - Inbox files

    /// Delivers the files that wait in the `inbox/` folder of the live
    /// durable session `id`, oldest first (see ``SessionInboxFile``). A
    /// session that is not live, or that is memory-only, has no inbox to
    /// scan, so nothing happens.
    ///
    /// One directory delivers the files of one session. The scan does not
    /// check who owns the recording root, and it makes no claim on a file.
    /// Two directories that scan one folder can both deliver a file, so the
    /// host must not run two live copies of one session.
    ///
    /// A file goes through the same delivery as a send
    /// (``hand(_:userHeader:to:ledger:isQueued:)``): its mail goes into the mail queue of the
    /// session, the ledger keeps the message with the `chainDepth` of the
    /// file, and `messageDelivered` follows when the pump takes the mail.
    /// Then the file is removed. The
    /// scan has no caller to throw to, so each failure is logged:
    ///
    /// - A file that does not parse moves to `inbox/rejected/`, and the scan
    ///   goes on with the next file.
    /// - A file whose id the ledger holds already, with no kept mark of an
    ///   archive, is removed with no second delivery. This is the state
    ///   after a crash between the ledger write and the removal of the file.
    ///   A kept message that a read marked read is removed too.
    /// - A file whose id the queue or an open answer of the session holds,
    ///   and the ledger does not (`MailRefusal.duplicateID`), is removed and
    ///   logged as a warning, and the scan goes on with the next file. The
    ///   refusal never ends later, because the mail with this id is already
    ///   in the session, so one bad file does not block the files after it.
    /// - A refusal of the mail because the session closed
    ///   (`MailRefusal.closed`), or a ledger that does not read, leaves the
    ///   file in `inbox/` and stops the scan of this session. The next scan
    ///   tries the file again.
    ///
    /// The scan is synchronous on the actor and has no suspension point, so
    /// no other scan or send runs between the check of the ledger and
    /// ``keep(_:in:)``. Two scans thus deliver one file one time.
    ///
    /// The scan delivers a file when the ledger has no message with its id,
    /// or when an archive kept the message there and no read marked it read
    /// (``SessionMessageLedger/awaitsDelivery(of:)``, D204). A session that
    /// an archive stops now is not scanned (``isArchiving(_:)``): its files
    /// stay in `inbox/`, so no mail goes into its queue after the stop. A
    /// live session whose record holds `archivedAt` (a client opened an
    /// archived session with `session/load`) is not scanned too: it stays
    /// archived and starts no turn, and its files wait for
    /// ``unarchive(_:by:)``, which scans the inbox.
    ///
    /// - Parameter id: The session id.
    func scanInbox(of id: ULID) {
        guard let session = session(id: id), session.facts.archivedAt == nil, !isArchiving(id),
            let folder = Self.ledgerDirectory(of: session)
        else {
            return
        }
        let files: [URL]
        do {
            files = try SessionInboxFile.pending(in: folder)
        } catch {
            logInboxFailure("the inbox folder of a session did not read", error, session: id, file: nil)
            return
        }
        for file in files {
            guard deliverInboxFile(file, to: session, in: folder) else { return }
        }
    }

    /// Delivers one inbox file to its session, and removes the file.
    ///
    /// - Parameters:
    ///   - file: A file of the inbox folder.
    ///   - session: The live durable session that owns the inbox.
    ///   - folder: The session folder.
    /// - Returns: `true` when the scan goes on with the next file, `false`
    ///   when the file stays and the scan stops.
    private func deliverInboxFile(_ file: URL, to session: any RoutedSession, in folder: URL) -> Bool {
        let message: SessionInboxMessage
        do {
            message = try SessionInboxFile.read(file, maxMessageBytes: limits.maxMessageBytes)
        } catch let error as SessionInboxFileError {
            rejectInboxFile(file, in: folder, because: error, session: session.id)
            return true
        } catch {
            logInboxFailure("an inbox file did not read; it stays in the inbox", error, session: session.id, file: file)
            return true
        }
        do {
            let ledger = try ledger(of: session.id, in: folder)
            if ledger.awaitsDelivery(of: message.id) {
                try hand(
                    Self.delivered(message, to: session.id), userHeader: userHeader(of: message), to: session,
                    ledger: ledger)
            }
        } catch MailRefusal.duplicateID(let duplicate) {
            logInboxDuplicate(duplicate, session: session.id, file: file)
        } catch {
            logInboxFailure(
                "an inbox file did not deliver; it stays in the inbox", error, session: session.id, file: file)
            return false
        }
        removeInboxFile(
            file, session: session.id,
            failure: "a delivered inbox file did not remove; the next scan removes it, because the ledger holds its id")
        return true
    }

    /// Moves an inbox file that does not parse to `inbox/rejected/`, and logs
    /// the error of the parse.
    ///
    /// - Parameters:
    ///   - file: A file of the inbox folder.
    ///   - folder: The session folder.
    ///   - error: The error of the parse.
    ///   - id: The session id.
    private func rejectInboxFile(_ file: URL, in folder: URL, because error: any Error, session id: ULID) {
        logInboxFailure("an inbox file does not parse; it moves to inbox/rejected", error, session: id, file: file)
        do {
            try SessionInboxFile.reject(file, in: folder)
        } catch {
            logInboxFailure(
                "an inbox file that does not parse did not move; it stays in the inbox", error, session: id,
                file: file)
        }
    }

    /// Removes an inbox file. A removal that fails is logged, and the file
    /// stays.
    ///
    /// - Parameters:
    ///   - file: A file of the inbox folder.
    ///   - id: The session id.
    ///   - what: What the log says when the removal fails, and what happens
    ///     to the file.
    private func removeInboxFile(_ file: URL, session id: ULID, failure what: String) {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            logInboxFailure(what, error, session: id, file: file)
        }
    }

    /// Logs a failure of the inbox scan.
    ///
    /// - Parameters:
    ///   - what: What failed, and what happens to the file.
    ///   - error: The error.
    ///   - id: The session id.
    ///   - file: The inbox file, or `nil` for a failure of the folder.
    private nonisolated func logInboxFailure(_ what: String, _ error: any Error, session id: ULID, file: URL?) {
        logInbox(.error, what, session: id, file: file, error: error)
    }

    /// Logs a warning for an inbox file whose mail id the session holds
    /// already. The file is removed after the log.
    ///
    /// - Parameters:
    ///   - message: The mail id of the file.
    ///   - id: The session id.
    ///   - file: The inbox file.
    private nonisolated func logInboxDuplicate(_ message: MailID, session id: ULID, file: URL) {
        logInbox(
            .warning, "an inbox file has the mail id of a mail that the session holds; the file is removed",
            session: id, file: file,
            metadata: [RouterTelemetry.LogMetadataKey.messageId: "\(message.description)"])
    }

    /// Logs an event of the inbox scan. The one place that adds the file path
    /// to the metadata.
    ///
    /// - Parameters:
    ///   - level: The log level.
    ///   - what: What happened, and what happens to the file.
    ///   - id: The session id.
    ///   - file: The inbox file, or `nil` for an event of the folder.
    ///   - error: The error of a failure, or `nil` for an event that is not
    ///     a failure.
    ///   - metadata: The metadata that is specific to the event.
    private nonisolated func logInbox(
        _ level: Logger.Level, _ what: String, session id: ULID, file: URL?,
        error: (any Error)? = nil, metadata: Logger.Metadata = [:]
    ) {
        var metadata = metadata
        if let file {
            metadata[RouterTelemetry.LogMetadataKey.filePath] = "\(file.path)"
        }
        Self.logSession(level, what, session: id, error: error, metadata: metadata)
    }

    /// Logs an event of the session `id` through the logger of the session
    /// directory. The one place that adds the session id, and the metadata of
    /// `error`, to the metadata of a log of one session.
    ///
    /// - Parameters:
    ///   - level: The log level.
    ///   - message: What happened, and what the directory does next.
    ///   - id: The session id.
    ///   - error: The error of a failure, or `nil` for an event that is not
    ///     a failure.
    ///   - metadata: The metadata that is specific to the event.
    private static func logSession(
        _ level: Logger.Level, _ message: String, session id: ULID,
        error: (any Error)? = nil, metadata: Logger.Metadata = [:]
    ) {
        var metadata = metadata
        if let error {
            metadata.merge(RouterTelemetry.errorMetadata(error)) { specific, _ in specific }
        }
        metadata[RouterTelemetry.LogMetadataKey.sessionId] = "\(id.description)"
        RouterTelemetry.makeLogger(.sessionDirectory).log(level: level, "\(message)", metadata: metadata)
    }

    /// The record of an inbox message as the directory delivers it to
    /// `target` now. The id, the sender, the reply id, the source session and
    /// the chain depth are the ones of the file.
    ///
    /// - Parameters:
    ///   - message: The message of the file.
    ///   - target: The session id of the target.
    /// - Returns: The delivered message, not read.
    private static func delivered(_ message: SessionInboxMessage, to target: ULID) -> SessionMessage {
        delivered(
            OutgoingSessionMessage(
                from: message.from, to: .session(target), text: message.text, inReplyTo: message.inReplyTo,
                sourceSession: message.sourceSession),
            id: message.id, chainDepth: message.chainDepth, to: target)
    }

    /// The header of an inbox message from a user sender that names its
    /// source session (``UserMessageHeader``, D199 (f)).
    ///
    /// The header line of the file is the one that the send made, so the
    /// title and the folder are the ones at the time of the send. A file with
    /// no header line (a file that a hand wrote) gets a header from the live
    /// summary of the source session now. The scan has no suspension point,
    /// so it does not read the recorded summaries: a source session that is
    /// not live gives the header with its id only.
    ///
    /// - Parameter message: The message of the file.
    /// - Returns: The header, or `nil` for a message from a session or a
    ///   message with no source session.
    private nonisolated func userHeader(of message: SessionInboxMessage) -> UserMessageHeader? {
        guard case .user = message.from, let source = message.sourceSession else { return nil }
        guard let line = message.userHeader else {
            return UserMessageHeader(source: source, summary: liveSummary(of: source))
        }
        return UserMessageHeader(line: line)
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
    /// The read is how the target gets each marked message whose mail still
    /// waits, so the read sends its `messageDelivered` event
    /// (``sendDelivered(_:)``), before the cancel. A mail that the pump
    /// takes after the read gives no second event.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - markRead: True to mark the messages read, and withdraw their
    ///     mail that still waits.
    /// - Returns: The messages to the session that were not read, the
    ///   oldest first.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id,
    ///   `JSONLFileError.readFailed(description:)` when the `messages.jsonl`
    ///   of the session exists and does not read, or the error of the
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
        sendDelivered(unread.map(\.id))
        await withdrawWaitingMail(unread.map(\.id), from: id)
        return unread
    }

    /// Sends the `messageDelivered` event of each message of `ids` that
    /// still waits for its delivery (``Registry/sendDelivered(_:)``): the
    /// read of the inbox is how its target gets it, because its mail leaves
    /// the queue and starts no turn. A message that the pump took already
    /// gave its event, and gives no second one.
    ///
    /// - Parameter ids: The ids of the messages that the inbox marked read.
    private nonisolated func sendDelivered(_ ids: [MailID]) {
        state.withLock { registry in
            for id in ids {
                registry.sendDelivered(id)
            }
        }
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
        guard !ids.isEmpty, let session = session(id: id) else { return }
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
    /// - Throws: `JSONLFileError.readFailed(description:)` when the
    ///   `messages.jsonl` of `recipient` exists and does not read, or the
    ///   error of the recording roots of the host.
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
        if let session = session(id: id) {
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
    /// - Throws: `JSONLFileError.readFailed(description:)` when the
    ///   `messages.jsonl` of the session exists and does not read.
    private func ledger(of id: ULID, in directory: URL?) throws -> SessionMessageLedger {
        if let held = ledgers[id] {
            return held
        }
        return try SessionMessageLedger.load(from: directory)
    }

    /// The folder of the recorded session `id` under the recording roots of
    /// the host and of the usage store (``allRecordingRoots()``): the folder
    /// named by the id in the first root that holds one.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The folder, or `nil` when no root holds one.
    /// - Throws: The error of the recording roots of the host.
    private func recordedFolder(of id: ULID) async throws -> URL? {
        try await allRecordingRoots()
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
        guard let actor = session as? RoutedSessionActor, actor.persistsIndex else { return nil }
        return session.recordingDirectory
    }

    /// The live session `id`, at any depth of the session tree.
    ///
    /// A host uses it for a sub-agent session it reads from a `started`
    /// event of ``events()``. The session gives its own feed
    /// (``RoutedSession/streamSessionEvents()``) and its answer path
    /// (``RoutedSession/respond(elicitationId:response:)``). The directory is
    /// flat: each vended or restored session has one entry, so a root, a
    /// sub-agent and a sub-agent of a sub-agent follow the same rule.
    ///
    /// The directory holds each session weakly, so this call does not keep
    /// the session alive. A host that wants the session to stay must hold the
    /// result. A session that closed gives `nil`.
    ///
    /// The session is registered before its `started` event goes out. So a
    /// host that reads `started` and then calls this method finds the
    /// session, unless it closed in the meantime.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The session, or `nil` when the directory holds no live
    ///   session with the id.
    public nonisolated func session(id: ULID) -> (any RoutedSession)? {
        state.withLock { $0.entries[id]?.session }
    }

    /// Suspends every live session of the directory (``RoutedSession/suspend()``),
    /// in one step.
    ///
    /// A host that quits the process calls this before it closes the first
    /// session. The runs of every session then stay open in the journal, also
    /// those of a child that ends its work while the parent closes. The call
    /// does not wait, and it closes nothing. A session that left the live list
    /// (a closed session) is not suspended: it has no open run to keep.
    ///
    /// A suspended session gets no ended marker
    /// (``markEnded(_:reason:)``), so a child that ends by itself after this
    /// call stays restorable, with its result still to be given. The
    /// directory keeps the ids of these sessions, so the marker is refused
    /// also after the session is closed.
    public nonisolated func suspendLiveSessions() {
        let sessions = state.withLock { registry in
            let sessions = registry.entries.values.compactMap(\.session)
            registry.suspendedIDs.formUnion(sessions.map(\.id))
            return sessions
        }
        for session in sessions {
            session.suspend()
        }
    }

    // MARK: - Record changes

    /// Sets the folders a host added to the working folder of the session
    /// `id` (``SessionRecord/additionalDirectories``), rewrites the `index.md`
    /// of the session, and sends `factsChanged` with its summary. The folders
    /// the session holds already change nothing and send no event
    /// (``changeRecord(of:_:)``).
    ///
    /// - Parameters:
    ///   - directories: The added folders, in the order the host gives them.
    ///   - id: The session id.
    /// - Returns: The summary of the session after the change.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id, the error of the recording roots of the
    ///   host, or the error of the read or the save of the `index.md` of a
    ///   recorded session that is not live.
    @discardableResult
    public func setAdditionalDirectories(to directories: [URL], for id: ULID) async throws -> SessionSummary {
        try await changeRecord(of: id) { $0.additionalDirectories = directories }
    }

    /// Changes the record of the session `id` and sends `factsChanged` with
    /// its summary: the one path of each change of a record from the
    /// directory.
    ///
    /// A live session changes its own record (``RoutedSessionActor/updateRecord(_:)``),
    /// which saves its `index.md` best effort, and its live entry stamps the
    /// time of the change. A recorded session that is not live is read from
    /// the `index.md` of its folder, changed, and saved back; a failed save
    /// throws, because no session goes on to hold the change.
    ///
    /// A change that leaves the record as it was gives the summary and sends
    /// no event; a recorded session's `index.md` is then not written.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: The change to apply to the record.
    /// - Returns: The summary of the session after the change.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id, or when the live session is not a
    ///   ``RoutedSessionActor``; the error of the recording roots of the
    ///   host; or the error of the read or the save of the `index.md` of a
    ///   recorded session.
    private func changeRecord(
        of id: ULID, _ change: @Sendable (inout SessionRecord) -> Void
    ) async throws -> SessionSummary {
        if let session = session(id: id) {
            return try changeLiveRecord(of: session, change)
        }
        let (summary, changed) = try await changeRecordedRecord(of: id, change)
        if changed {
            emit(.factsChanged(summary))
        }
        return summary
    }

    /// Changes the record of the recorded session `id`, which is not live:
    /// reads the `index.md` of its folder, changes the record, and saves it
    /// back when the change altered it. A failed save throws, because no
    /// session goes on to hold the change. The call sends no event; the
    /// caller sends the one its change calls for. A record with no title
    /// gets its default name first (``recordedSummaries()``), thus the
    /// change starts from the named record.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - change: The change to apply to the record.
    /// - Returns: The recorded summary after the change, and whether the
    ///   change altered the record. A record the change left as it was is
    ///   not written.
    /// - Throws: `SessionDirectoryError.unknownSession` when no session
    ///   folder under the recording roots holds an `index.md` for the id; the
    ///   error of the recording roots of the host; or the error of the read
    ///   or the save of the `index.md`.
    private func changeRecordedRecord(
        of id: ULID, _ change: (inout SessionRecord) -> Void
    ) async throws -> (summary: SessionSummary, changed: Bool) {
        guard let folder = try await recordedFolder(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        if let untitled = try SessionIndexFile.read(in: folder), SessionDefaultTitle.isMissing(in: untitled.facts) {
            _ = try await recordedSummaries()
        }
        guard let stored = try SessionIndexFile.read(in: folder) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        var record = stored
        change(&record)
        guard record != stored else { return (recordedSummary(of: stored), false) }
        try SessionIndexFile.save(record, in: folder)
        return (recordedSummary(of: record), true)
    }

    /// Changes the record of a live session through the session itself, and
    /// sends `factsChanged` with its live summary (``recordFactsChange(of:)``)
    /// when the change altered the record. A change that leaves the record
    /// as it was sends no event and leaves the time of change of the entry.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - change: The change to apply to the record.
    /// - Returns: The live summary of the session after the change.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session is
    ///   not a ``RoutedSessionActor`` (``recordOwner(of:)``), or when it left
    ///   the directory before its summary was read.
    private func changeLiveRecord(
        of session: any RoutedSession, _ change: @Sendable (inout SessionRecord) -> Void
    ) throws -> SessionSummary {
        let actor = try Self.recordOwner(of: session)
        var changed = false
        actor.updateRecord { record in
            let before = record
            change(&record)
            changed = record != before
        }
        if changed {
            recordFactsChange(of: session.id)
        }
        return try requireLiveSummary(of: session.id)
    }

    /// The live session as the one type that can change its record.
    ///
    /// Only a ``RoutedSessionActor`` can change its record. Each session that
    /// a router vends is one, so another live session is a surprise: the
    /// call stops a debug build, logs the surprise, and throws, so the
    /// caller changes nothing.
    ///
    /// - Parameter session: The live session.
    /// - Returns: The session as a ``RoutedSessionActor``.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session is
    ///   not a ``RoutedSessionActor``.
    private static func recordOwner(of session: any RoutedSession) throws -> RoutedSessionActor {
        guard let actor = session as? RoutedSessionActor else {
            assertionFailure("a live session that cannot change its record")
            logSession(
                .error, "a live session cannot change its record; the record stays as the session holds it",
                session: session.id)
            throw SessionDirectoryError.unknownSession(session.id)
        }
        return actor
    }

    /// The summary of the live session `id`, which the caller holds.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The live summary.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session left
    ///   the directory.
    private nonisolated func requireLiveSummary(of id: ULID) throws -> SessionSummary {
        guard let summary = liveSummary(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return summary
    }

    // MARK: - Ended marker

    /// Marks the session `id` as ended (``SessionEndedMarker``), for the host that
    /// owns the run lifecycle: the host calls it after a run reaches a
    /// terminal state. An ended session has no work to restore, and its
    /// recording stays for history.
    ///
    /// The call writes `endedAt` and `endReason` to the `index.md` of the
    /// session before it returns, for a live session
    /// (``RoutedSessionActor/updateRecord(_:)``) and for a recorded session
    /// that is not live alike (``changeRecord(of:_:)``). It does not close
    /// the session, stop its work or send `archived`; the one event is the
    /// `factsChanged` of ``changeRecord(of:_:)``. A close of a session never
    /// sets the marker, because a close at the shutdown of the process, while
    /// a run works, must stay restorable.
    ///
    /// A session that is ended already gives its first marker again, and its
    /// `index.md` is not written.
    ///
    /// A live session that is suspended (``RoutedSession/suspend()``) gets no
    /// marker. The call writes nothing, sends no event, and throws
    /// ``SessionEndedMarkerError/sessionSuspended(_:)``. The journal refuses
    /// the result of a run after the suspend, so a marker would hide the
    /// session from the restore and lose that result. The host treats the
    /// error as "left open on purpose": it does not retry, and the next
    /// process restores the session. The check is made before the write,
    /// as the journal check is: a suspend that comes after it does not undo
    /// the marker. A session that was suspended and then closed is refused in
    /// the same way: the directory keeps the id of a session that left the
    /// live list while suspended, because the orderly shutdown suspends and
    /// closes the child before the host marks it. A recorded session that
    /// this process never suspended is marked as before.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - reason: Why the session ended.
    /// - Returns: The marker the session holds: the new one, or the first one
    ///   when the session was ended already.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id; ``SessionEndedMarkerError/sessionSuspended(_:)``
    ///   when the session is suspended, or was suspended before its close; the error of the recording roots
    ///   of the host; or the error of the read or the save of the `index.md`
    ///   of a recorded session.
    @discardableResult
    public func markEnded(_ id: ULID, reason: SessionEndReason) async throws -> SessionEndedMarker {
        guard !wasSuspended(id) else { throw SessionEndedMarkerError.sessionSuspended(id) }
        let endedAt = MillisecondDate.rounded(Date())
        _ = try await changeRecord(of: id) { record in
            guard record.facts.end == nil else { return }
            record.facts.endedAt = endedAt
            record.facts.endReason = reason
        }
        return try await requireEndMarker(of: id)
    }

    /// Whether the session `id` is suspended now, or this process saw it
    /// suspended before it left the live list.
    private nonisolated func wasSuspended(_ id: ULID) -> Bool {
        state.withLock { $0.suspendedIDs.contains(id) || $0.entries[id]?.session?.isSuspended == true }
    }

    /// The ended marker of the session `id`, or `nil` when the session is not
    /// ended. A live session answers from its facts; a recorded session that
    /// is not live answers from the `index.md` of its folder.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The marker, or `nil` for a session that is not ended.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id; the error of the recording roots of the
    ///   host; or the read error of the `index.md` of a recorded session.
    public func endMarker(of id: ULID) async throws -> SessionEndedMarker? {
        if let session = session(id: id) {
            return session.facts.end
        }
        guard let folder = try await recordedFolder(of: id), let record = try SessionIndexFile.read(in: folder) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return record.facts.end
    }

    /// The subagent sessions of the parent session `parent` that are not
    /// ended: the live ones and the recorded ones under the recording roots.
    /// A host lists the children it can still restore with this call.
    /// ``RecordedSessions`` lists the sessions whose folder is a direct entry
    /// of a recording root, so a child whose folder sits inside the folder of
    /// its parent is not in the answer.
    ///
    /// - Parameter parent: The id of the parent session.
    /// - Returns: The summaries of the unended children, newest first.
    /// - Throws: The error of ``sessions(matching:)`` or of
    ///   ``endMarker(of:)``.
    public func unendedChildren(of parent: ULID) async throws -> [SessionSummary] {
        let children = try await sessions(
            matching: SessionQuery(kind: .subagent, parentID: parent, includesRecorded: true, limit: .max))
        var unended: [SessionSummary] = []
        for child in children where try await endMarker(of: child.id) == nil {
            unended.append(child)
        }
        return unended
    }

    // MARK: - Recorded children and run statuses

    /// The recorded sub-agent sessions of the parent session `parent`, read
    /// from their `index.md` files. The call restores nothing, writes
    /// nothing and starts nothing.
    ///
    /// A child is a record that holds an agent spawn
    /// (``SessionRecord/agentSpawn``) of `parent`. The call finds a child at
    /// any depth under a recording root, so a child whose folder sits inside
    /// the folder of its parent is in the answer too. It reads recorded
    /// children only: a child with no `index.md` on disk is not in it.
    ///
    /// A child whose run wrote no journal event is in this answer and has no
    /// entry in ``runStatuses(of:)``.
    ///
    /// - Parameter parent: The id of the parent session.
    /// - Returns: The recorded children, newest first.
    /// - Throws: The error of the recording roots of the host, the read
    ///   error of an `index.md`, or the errors of ``firstPrompt(of:)`` for the
    ///   transcript of a child.
    public func recordedChildren(of parent: ULID) async throws -> [RecordedChild] {
        try RecordedSessions(roots: try await allRecordingRoots()).nestedEntries()
            .filter { $0.record.agentSpawn?.parentSessionId == parent }
            .compactMap { entry in
                RecordedChild(
                    record: entry.record,
                    firstPrompt: try FirstPromptReader.firstPrompt(ofSessionIn: entry.folder, record: entry.record))
            }
    }

    /// The text of the first prompt of the recorded session `session`, read
    /// without a restore. The call restores nothing, writes nothing and
    /// starts nothing.
    ///
    /// The read goes through the `transcript.jsonl` of the session line by
    /// line, and stops at the first `.prompt` event or the first
    /// ``TranscriptEvent/Kind/promptStarted`` marker. The marker is the
    /// write-ahead record of the prompt: a session that a crash cut in its
    /// first submission has the marker and no `.prompt` entry. It loads no
    /// other event, no other session and no tree. A fork reads the events of its parents up
    /// to its cut, as a restore of the fork does, and then its own events.
    ///
    /// The text is the prompt body as recorded. A submission can deliver mail
    /// with its prompt: the run mail that comes before the prompt, and the
    /// mail records that the prompt entry carries, are no part of the text.
    /// When the submission has user mail and no other prompt text, the text
    /// of that mail is the prompt.
    ///
    /// - Parameter session: The id of the recorded session.
    /// - Returns: The first prompt, or `nil` when the transcript holds no
    ///   prompt, or when its first prompt has no text.
    /// - Throws: `SessionDirectoryError.unknownSession` when no recording
    ///   root holds the session; the error of the recording roots of the
    ///   host; ``TranscriptTreeError`` (`indexUnreadable`, `indexMissing`,
    ///   `duplicateSessionId`);
    ///   ``RecordingSchemaVersionError`` for a record of a newer router; and
    ///   `JSONLFileError.readFailed(description:)` for a transcript that does
    ///   not read.
    public func firstPrompt(of session: ULID) async throws -> String? {
        for root in try await allRecordingRoots() where FileManager.default.fileExists(atPath: root.path) {
            guard let folder = try TranscriptTree.sessionFolder(of: session, under: root) else { continue }
            return try FirstPromptReader.firstPrompt(ofSessionIn: folder)
        }
        throw SessionDirectoryError.unknownSession(session)
    }

    /// The status of each journaled run of the recorded session `session`:
    /// one entry for each run key that has a journal event in the effective
    /// events of the session. The call restores nothing and posts no `.lost`
    /// terminal.
    ///
    /// A run is ``RunStatus/completed(_:)`` when the journal holds a
    /// `.completed` event of it, else ``RunStatus/orphaned``. The orphaned
    /// runs are exactly the runs that a restore of the session marks as lost,
    /// because both use one scan (``OrphanRunScan``).
    ///
    /// A host that restarts restores a child only when the child is not ended
    /// and the run of its ``RecordedChild/parentToolCallId`` is not completed.
    /// If the host stopped after the `.completed` event of the run reached
    /// the journal of the parent and before ``markEnded(_:reason:)``, the
    /// child looks unended, and the completed status shows it.
    ///
    /// - Parameter session: The id of the recorded session.
    /// - Returns: The status of each run key.
    /// - Throws: `SessionDirectoryError.unknownSession` when no recording
    ///   root holds the session; the error of the recording roots of the
    ///   host; or a typed error for a recording that is damaged: see below.
    ///
    /// The call reads the chain of the session only: the session and, for a
    /// fork, each session it nests under. It does not read a sibling, a
    /// child or any other session of the recording root. So a damaged record
    /// of another session does not fail the call. A host can turn the typed
    /// error of a damaged chain into "unknown" for the affected child, and
    /// it can still restore the root. The typed errors are
    /// ``TranscriptTreeError`` (`indexUnreadable`, `indexMissing`,
    /// `forkCutPointMissing`, `duplicateSessionId`),
    /// ``RecordingSchemaVersionError`` for a record of a newer router, and
    /// `JSONLFileError.readFailed(description:)` for a transcript that does
    /// not read.
    public func runStatuses(of session: ULID) async throws -> [RunKey: RunStatus] {
        for root in try await allRecordingRoots() where FileManager.default.fileExists(atPath: root.path) {
            guard let folder = try TranscriptTree.sessionFolder(of: session, under: root) else { continue }
            let tree = try TranscriptTree.loadChain(ofSessionIn: folder, under: root)
            return OrphanRunScan(scanning: try tree.effectiveEntryEvents(forSession: session)).statuses
        }
        throw SessionDirectoryError.unknownSession(session)
    }

    /// The ended marker of the session `id`, which the caller marked just
    /// now.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The marker.
    /// - Throws: What ``endMarker(of:)`` throws; `unknownSession` when the
    ///   session holds no marker after the mark.
    private func requireEndMarker(of id: ULID) async throws -> SessionEndedMarker {
        guard let end = try await endMarker(of: id) else {
            throw SessionDirectoryError.unknownSession(id)
        }
        return end
    }

    // MARK: - Tags and title

    /// See `SessionDirectory.addTags(_:to:)`. Checks each tag against the
    /// tag rule (``SessionTagRule``) before it changes anything, then joins
    /// the tags to the tags of the session through ``changeRecord(of:_:)``,
    /// which rewrites the `index.md` of the session and sends one
    /// `factsChanged`. Tags the session holds already change nothing, and a
    /// call that changes nothing sends no event. An archived session takes
    /// tags too: only messages are refused to it.
    ///
    /// - Parameters:
    ///   - tags: The tags to add.
    ///   - id: The session id.
    /// - Returns: The summary of the session with the new tags.
    /// - Throws: `SessionDirectoryError.invalidTag` with the first tag
    ///   outside the rule, in name order, and nothing changed;
    ///   `SessionDirectoryError.unknownSession` when no live or recorded
    ///   session has the id; or the error of the recording roots of the host,
    ///   or of the read or the save of the `index.md` of a recorded session
    ///   that is not live.
    @discardableResult
    public func addTags(_ tags: Set<String>, to id: ULID) async throws -> SessionSummary {
        try SessionTagRule.validate(tags)
        return try await changeRecord(of: id) { $0.facts.tags.formUnion(tags) }
    }

    /// See `SessionDirectory.removeTags(_:from:)`. Checks each tag against
    /// the tag rule (``SessionTagRule``) before it changes anything, then
    /// takes the tags off the session through ``changeRecord(of:_:)``, which
    /// rewrites the `index.md` of the session and sends one `factsChanged`.
    /// Tags the session does not hold change nothing, and a call that changes
    /// nothing sends no event.
    ///
    /// - Parameters:
    ///   - tags: The tags to remove.
    ///   - id: The session id.
    /// - Returns: The summary of the session with the tags that stay.
    /// - Throws: `SessionDirectoryError.invalidTag` with the first tag
    ///   outside the rule, in name order, and nothing changed;
    ///   `SessionDirectoryError.unknownSession` when no live or recorded
    ///   session has the id; or the error of the recording roots of the host,
    ///   or of the read or the save of the `index.md` of a recorded session
    ///   that is not live.
    @discardableResult
    public func removeTags(_ tags: Set<String>, from id: ULID) async throws -> SessionSummary {
        try SessionTagRule.validate(tags)
        return try await changeRecord(of: id) { $0.facts.tags.subtract(tags) }
    }

    /// See `SessionDirectory.setTitle(_:of:)` (Rename, a control action:
    /// TestudoApp D84). Sets the title of the session through
    /// ``changeRecord(of:_:)``, which rewrites the `index.md` of the session,
    /// so ``recordedSessions(in:)`` reads the new title back, and sends one
    /// `factsChanged`. The title the session holds already changes nothing,
    /// and sends no event. An archived session can be renamed too.
    ///
    /// - Parameters:
    ///   - title: The new title.
    ///   - id: The session id.
    /// - Returns: The summary of the session with the new title.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id, or the error of the recording roots of
    ///   the host, or of the read or the save of the `index.md` of a recorded
    ///   session that is not live.
    @discardableResult
    public func setTitle(_ title: String, of id: ULID) async throws -> SessionSummary {
        try await changeRecord(of: id) { $0.facts.title = title }
    }

    // MARK: - Archive

    /// See `SessionDirectory.archive(_:by:)` (ROUTER-11, D68, D204): hides
    /// the session `id`. An archive is not final:
    /// ``unarchive(_:by:)`` is the inverse. While the session is archived,
    /// a send to it writes the message to its inbox with the note
    /// ``archivedNote``, the message starts no turn, and the directory does
    /// not restore it.
    ///
    /// - A live session stops its work (``archiveLive(_:by:)``): its running
    ///   turn ends cancelled. Each message that waits in its queue leaves the
    ///   queue with no delivery and no `messageDelivered`, and stays an
    ///   unread message of its inbox: a file in its `inbox/` folder. The
    ///   files of the `inbox/` folder stay. Its `index.md` gets `archivedAt`,
    ///   it leaves the live list and closes, and the directory sends
    ///   `stateChanged` with `archived` and then `archived`.
    /// - A recorded session that is not live gets `archivedAt` in the
    ///   `index.md` of its folder, and the same two events
    ///   (``archiveRecorded(_:by:)``). The launcher gets no call.
    /// - A session that is archived already gives its summary again and
    ///   sends no event.
    ///
    /// `archiver` goes to the log with the session id, for the audit. It is
    /// not a fact of the session. Router puts no limit on an archive.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it.
    /// - Returns: The summary of the archived session. It is not live.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id, or when the live session is not a
    ///   ``RoutedSessionActor``; the error of the recording roots of the
    ///   host; or the error of the read or the save of the `index.md` of a
    ///   recorded session.
    @discardableResult
    public func archive(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary {
        guard let session = session(id: id) else {
            return try await archiveRecorded(id, by: archiver)
        }
        return try await archiveLive(session, by: archiver)
    }

    /// Archives a live session. The stop of its work and the write of
    /// `archivedAt` come with no suspension between them, so a message that
    /// a send sends after the call began goes to the inbox as archived.
    ///
    /// An archive keeps the mail (D204):
    ///
    /// 1. The directory starts to keep the mail of the session
    ///    (``Registry/startKeepingMail(of:)``), and no scan of its inbox
    ///    runs from now on (``isArchiving(_:)``): the files of its `inbox/`
    ///    folder stay there. Then ``RoutedSession/cancelAll()`` stops the
    ///    running turn, as a cancel does, and takes each waiting mail out of
    ///    the queue, also the mail of a message that waits for the end of
    ///    the turn. Each such mail ends with no delivery, so the directory
    ///    keeps its message and sends no `messageDelivered`.
    /// 2. ``RoutedSessionActor/updateRecord(_:)`` writes `archivedAt`, and
    ///    the session saves its `index.md`.
    /// 3. The call waits for the end of the cancel (``awaitEnd(of:in:)``).
    /// 4. The session leaves the live list with its work state `archived`
    ///    (``takeArchived(_:)``), and the kept messages go to its inbox
    ///    (``keepInInbox(_:of:)``). Then the session closes.
    /// 5. `stateChanged` with `archived`, then `archived`, go out.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - archiver: The session or the user that archives it.
    /// - Returns: The summary of the archived session, or its live summary
    ///   when its record holds `archivedAt` already.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session is
    ///   not a ``RoutedSessionActor``, or when it left the directory.
    private func archiveLive(_ session: any RoutedSession, by archiver: SessionMessageSender) async throws
        -> SessionSummary
    {
        guard session.facts.archivedAt == nil else { return try requireLiveSummary(of: session.id) }
        let actor = try Self.recordOwner(of: session)
        state.withLock { $0.startKeepingMail(of: session.id) }
        let stop = session.cancelAll()
        let archivedAt = MillisecondDate.rounded(Date())
        actor.updateRecord { $0.facts.archivedAt = archivedAt }
        await Self.awaitEnd(of: stop, in: session)
        let (summary, kept) = try takeArchived(session.id)
        keepInInbox(kept, of: session)
        await session.close()
        sendArchived(session.id, by: archiver)
        return summary
    }

    /// Archives a recorded session that is not live: writes `archivedAt` to
    /// the `index.md` of its folder (``changeRecordedRecord(of:_:)``) and
    /// sends `stateChanged` with `archived`, then `archived`. A record that
    /// holds `archivedAt` already is not written, and no event goes out.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - archiver: The session or the user that archives it.
    /// - Returns: The recorded summary of the archived session.
    /// - Throws: What ``changeRecordedRecord(of:_:)`` throws.
    private func archiveRecorded(_ id: ULID, by archiver: SessionMessageSender) async throws -> SessionSummary {
        let archivedAt = MillisecondDate.rounded(Date())
        let (summary, changed) = try await changeRecordedRecord(of: id) { record in
            record.facts.archivedAt = record.facts.archivedAt ?? archivedAt
        }
        if changed {
            sendArchived(id, by: archiver)
        }
        return summary
    }

    /// Waits for the end of the cancel signal `stop` of `session`.
    ///
    /// A wait that cannot run is not an error of the archive, so the call
    /// logs it and goes on: a session that archives itself from its own
    /// turn cannot wait inside its own submission, and a session that
    /// closed meanwhile has no work left. The close that follows ends the
    /// work in each case.
    ///
    /// - Parameters:
    ///   - stop: The id of the ``RoutedSession/cancelAll()`` signal.
    ///   - session: The session that runs the signal.
    private static func awaitEnd(of stop: SignalID, in session: any RoutedSession) async {
        do {
            _ = try await session.awaitTerminal(of: stop)
        } catch {
            logSession(
                .debug, "the archive did not wait for the cancel of the session; its close ends the work",
                session: session.id, error: error)
        }
    }

    /// Takes the session `id` off the live list as archived, under the lock
    /// of the registry: its entry leaves, the task that follows its state
    /// ends, and its work state becomes `archived`
    /// (``SessionStateTracking/archive()``), so no later event of the
    /// session changes it. The keep of its mail ends: each message to it
    /// whose mail the archive took out of its queue, and each message to it
    /// that still waits for its delivery, leaves with no event
    /// (``Registry/takeKeptMail(of:)``).
    ///
    /// - Parameter id: The session id.
    /// - Returns: The summary of the archived session, not live, changed
    ///   now, and the kept messages.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session left
    ///   the directory. Its unregistration then ended the keep of its mail.
    private nonisolated func takeArchived(_ id: ULID) throws -> (summary: SessionSummary, kept: [AwaitedDelivery]) {
        var kept: [AwaitedDelivery] = []
        let summary = try changeLiveEntry(of: id) { registry, entry in
            registry.entries[id] = nil
            entry.cancelFeeds()
            kept = registry.takeKeptMail(of: id)
            entry.tracking.archive()
        }
        return (summary, kept)
    }

    /// Whether an archive of the session `id` stops it now
    /// (``Registry/keptMail``): from the start of the archive of a live
    /// session until it leaves the live list.
    ///
    /// - Parameter id: The session id.
    /// - Returns: `true` while the archive keeps the mail of the session.
    private nonisolated func isArchiving(_ id: ULID) -> Bool {
        state.withLock { $0.keptMail[id] != nil }
    }

    /// Keeps each message of `kept` as an unread message of the inbox of the
    /// archived durable session `session` (D204). The ledger of the session
    /// marks the message kept (``SessionMessageLedger/markKept(_:)``), and
    /// the message goes back to a file in its `inbox/` folder, with the same
    /// id (``writeKeptFile(_:to:session:)``). The ledger already holds the
    /// message as unread, so ``inbox(of:markRead:)`` reads it. When a host
    /// opens the session after an unarchive, the scan of its inbox delivers
    /// the file, and `messageDelivered` comes then.
    ///
    /// A memory-only session has no `inbox/` folder, and it cannot open
    /// again after its archive. Its kept messages get no file: their mail
    /// ended cancelled, and no `messageDelivered` ever comes for them.
    ///
    /// The mark comes before the file, so a crash between the two leaves an
    /// unread message with no file, never a file that the scan removes as
    /// delivered. A failure of the ledger or of a file is logged, and the
    /// message stays unread in the ledger with no file.
    ///
    /// - Parameters:
    ///   - kept: The kept messages of the session.
    ///   - session: The archived session.
    private func keepInInbox(_ kept: [AwaitedDelivery], of session: any RoutedSession) {
        guard !kept.isEmpty, let folder = Self.ledgerDirectory(of: session) else { return }
        var ledger: SessionMessageLedger
        do {
            ledger = try self.ledger(of: session.id, in: folder)
        } catch {
            logInboxFailure(
                "the ledger of an archived session did not read; its kept messages get no inbox file", error,
                session: session.id, file: nil)
            return
        }
        for awaited in kept {
            ledger.markKept(awaited.message.id)
            writeKeptFile(awaited, to: folder, session: session.id)
        }
        ledgers[session.id] = ledger
    }

    /// Writes the kept message `awaited` as a file in the `inbox/` folder of
    /// a session folder, with the id, the sender (with its client id), the
    /// reply id, the chain depth and the source session of the message, and
    /// the header line of its prompt. A write that fails is logged.
    ///
    /// - Parameters:
    ///   - awaited: The kept message.
    ///   - folder: The session folder.
    ///   - id: The session id.
    private func writeKeptFile(_ awaited: AwaitedDelivery, to folder: URL, session id: ULID) {
        let message = awaited.message
        let file = SessionInboxMessage(
            id: message.id, from: message.from, inReplyTo: message.inReplyTo, chainDepth: message.chainDepth,
            text: message.text, sourceSession: message.sourceSession, userHeader: awaited.userHeader?.line)
        do {
            try SessionInboxFile.write(file, to: folder, maxMessageBytes: limits.maxMessageBytes)
        } catch {
            logInboxFailure(
                "a kept message of an archived session did not write to the inbox; it stays unread in the ledger",
                error, session: id, file: SessionInboxFile.url(of: message.id, in: folder))
        }
    }

    /// Sends `stateChanged` with `archived` and then `archived` for the
    /// session `id`, and writes the audit record of the archive to the log:
    /// the session id and `archiver`.
    ///
    /// - Parameters:
    ///   - id: The id of the archived session.
    ///   - archiver: The session or the user that archived it.
    private nonisolated func sendArchived(_ id: ULID, by archiver: SessionMessageSender) {
        sendArchiveChange(
            of: id, state: .archived, lastSummary: nil, event: .archived(id: id),
            log: "a session was archived", actorKey: RouterTelemetry.LogMetadataKey.archivedBy, actor: archiver)
    }

    /// Sends `stateChanged` with `state` and `lastSummary` for the session
    /// `id`, then `event`, and writes the audit record of the change to the
    /// log: the session id and the session or the user that made the change.
    /// ``sendArchived(_:by:)`` and ``sendUnarchived(_:by:)`` call it.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - state: The new state of the session.
    ///   - lastSummary: The last summary that `stateChanged` carries.
    ///   - event: The event of the change (`archived` or `unarchived`).
    ///   - message: The log message.
    ///   - actorKey: The log metadata key of `actor`.
    ///   - actor: The session or the user that made the change.
    private nonisolated func sendArchiveChange(
        of id: ULID, state: SessionState, lastSummary: String?, event: SessionDirectoryEvent,
        log message: String, actorKey: String, actor: SessionMessageSender
    ) {
        emit(.stateChanged(id: id, state: state, lastSummary: lastSummary))
        emit(event)
        Self.logSession(.notice, message, session: id, metadata: [actorKey: "\(actor)"])
    }

    // MARK: - Unarchive

    /// See `SessionDirectory.unarchive(_:by:)` (D204): removes `archivedAt`
    /// from the record of the session `id`. This is the inverse of
    /// ``archive(_:by:)``.
    ///
    /// - A recorded session that is not live loses `archivedAt` from the
    ///   `index.md` of its folder (``unarchiveRecorded(_:by:)``). It stays
    ///   recorded and not live, with the state `idle`, and the launcher gets
    ///   no call. A host opens it as it opens each recorded session, and the
    ///   session then reads its inbox.
    /// - A live session whose record holds `archivedAt` (a client opened it
    ///   with `session/load`) loses `archivedAt` from its record and its
    ///   `index.md`, and its tracked state is not archived now
    ///   (``unarchiveLive(_:by:)``). It stays live.
    /// - Then `stateChanged` with the new state, then `unarchived`, go out.
    /// - A session that is not archived gives its summary, writes nothing,
    ///   and sends no event.
    ///
    /// `unarchiver` goes to the log with the session id, for the audit. It
    /// is not a fact of the session. Router puts no limit on an unarchive.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - unarchiver: The session or the user that unarchives it.
    /// - Returns: The summary of the session after the call.
    /// - Throws: `SessionDirectoryError.unknownSession` when no live or
    ///   recorded session has the id, or when the live session is not a
    ///   ``RoutedSessionActor``; the error of the recording roots of the
    ///   host; or the error of the read or the save of the `index.md` of a
    ///   recorded session.
    @discardableResult
    public func unarchive(_ id: ULID, by unarchiver: SessionMessageSender) async throws -> SessionSummary {
        guard let session = session(id: id) else {
            return try await unarchiveRecorded(id, by: unarchiver)
        }
        return try unarchiveLive(session, by: unarchiver)
    }

    /// Unarchives a live session whose record holds `archivedAt`:
    /// ``RoutedSessionActor/updateRecord(_:)`` removes `archivedAt` and the
    /// session saves its `index.md`, the tracked state is not archived now
    /// (``takeUnarchived(_:)``), and ``sendUnarchived(_:by:)`` sends the
    /// events. Then the scan of the inbox delivers the files that waited
    /// while the session was archived (``scanInbox(of:)``), because no new
    /// file starts the watcher. A record with no `archivedAt` is not written,
    /// and no event goes out.
    ///
    /// - Parameters:
    ///   - session: The live session.
    ///   - unarchiver: The session or the user that unarchives it.
    /// - Returns: The live summary of the session after the call.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session is
    ///   not a ``RoutedSessionActor``, or when it left the directory.
    private func unarchiveLive(_ session: any RoutedSession, by unarchiver: SessionMessageSender) throws
        -> SessionSummary
    {
        guard session.facts.archivedAt != nil else { return try requireLiveSummary(of: session.id) }
        let actor = try Self.recordOwner(of: session)
        actor.updateRecord { $0.facts.archivedAt = nil }
        let summary = try takeUnarchived(session.id)
        sendUnarchived(summary, by: unarchiver)
        scanInbox(of: session.id)
        return summary
    }

    /// Unarchives a recorded session that is not live: removes `archivedAt`
    /// from the `index.md` of its folder (``changeRecordedRecord(of:_:)``)
    /// and sends the events (``sendUnarchived(_:by:)``). A record with no
    /// `archivedAt` is not written, and no event goes out.
    ///
    /// - Parameters:
    ///   - id: The session id.
    ///   - unarchiver: The session or the user that unarchives it.
    /// - Returns: The recorded summary of the session after the call.
    /// - Throws: What ``changeRecordedRecord(of:_:)`` throws.
    private func unarchiveRecorded(_ id: ULID, by unarchiver: SessionMessageSender) async throws -> SessionSummary {
        let (summary, changed) = try await changeRecordedRecord(of: id) { $0.facts.archivedAt = nil }
        if changed {
            sendUnarchived(summary, by: unarchiver)
        }
        return summary
    }

    /// Gives the live session `id` a tracked state that is not archived,
    /// under the lock of the registry (``SessionStateTracking/unarchive()``),
    /// and stamps the time of the change of its entry.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The live summary of the session, changed now.
    /// - Throws: `SessionDirectoryError.unknownSession` when the session left
    ///   the directory.
    private nonisolated func takeUnarchived(_ id: ULID) throws -> SessionSummary {
        try changeLiveEntry(of: id) { _, entry in entry.tracking.unarchive() }
    }

    /// Sends `stateChanged` with the state of `summary` and then
    /// `unarchived` for the session of `summary`, and writes the audit record
    /// of the unarchive to the log: the session id and `unarchiver`. The
    /// `stateChanged` carries the last summary only with `idle`, as the
    /// `SessionDirectory` port documents.
    ///
    /// - Parameters:
    ///   - summary: The summary of the unarchived session.
    ///   - unarchiver: The session or the user that unarchived it.
    private nonisolated func sendUnarchived(_ summary: SessionSummary, by unarchiver: SessionMessageSender) {
        let lastSummary = summary.state == .idle ? summary.lastSummary : nil
        sendArchiveChange(
            of: summary.id, state: summary.state, lastSummary: lastSummary, event: .unarchived(id: summary.id),
            log: "a session was unarchived", actorKey: RouterTelemetry.LogMetadataKey.unarchivedBy,
            actor: unarchiver)
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
    /// (ROUTER-5). The message cards enforce
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
    /// the registry. ``archive(_:by:)`` sends `archived` through it, and
    /// ``hand(_:userHeader:to:ledger:isQueued:)`` sends `messageDelivered` through it
    /// for a session that reports no fate of its mail. Each other
    /// `messageDelivered` event goes out under the same lock
    /// (``Registry/sendDelivered(_:)``).
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

    /// The number of inbox watchers that are open (``SessionInboxWatcher``):
    /// made by a registration and not cancelled yet. Only a test reads it,
    /// for the leak check. A watcher leaves the count when its session
    /// closes, when it is archived, and when a registration drops it.
    nonisolated var openInboxWatcherCount: Int {
        openInboxWatchers.current
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
        guard let session = session(id: id) else { return nil }
        return Set(await session.openElicitationIds().compactMap { ULID($0) })
    }
}
