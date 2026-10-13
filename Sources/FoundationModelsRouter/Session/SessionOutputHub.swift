import FoundationModelsExtras
import Synchronization

/// The output of one session: each ``SessionOutput`` goes from here to the
/// readers of the session (`mailbox.md`, section 5).
///
/// The hub has three kinds of reader:
///
/// - A feed (``makeFeed()``) gets each output of the session.
///   ``RoutedSession/streamSessionEvents()`` is a feed.
/// - A mail subscription (``subscribe(to:)``) gets each output that belongs
///   to one mail (``emit(_:failure:audience:)``), up to and including the
///   terminal event of that id. Then it finishes. ``RoutedSession/mail(_:)`` gives one.
/// - A waiter (``awaitTerminal(of:)``) waits for the terminal event of one
///   mail or one signal. The terminal events of a signal are
///   ``SessionEvent/signalDone(_:)``, and for a compaction
///   ``SessionEvent/compaction(_:)`` and ``SessionEvent/compactionFailed(_:)``.
///
/// Each feed and each subscription has its own unbounded buffer, so a slow
/// reader loses no output.
///
/// A caller can ask for a terminal event after it came, for example for the
/// id that a signal returns at once. Thus the hub keeps a ledger of the
/// terminal events of the most recent ids: at most ``ledgerCapacity`` ids,
/// and the oldest id leaves first. A wait for an id that left the ledger
/// waits until ``close()``. The ledger also keeps the error of a failed
/// answer next to its ``SessionEvent/answerFailed(_:)``: the helpers on top
/// of the core throw that error, and the public event does not carry it.
///
/// Each operation holds one lock and does not suspend, so a call from any
/// task, also a synchronous call that is not on the session actor, reaches
/// the hub at once.
final class SessionOutputHub: Sendable {
    /// The id that one terminal event ends.
    enum TerminalKey: Hashable, Sendable {
        /// The id of one mail.
        case mail(MailID)

        /// The id of one signal, in its string form. The ids of the
        /// compaction events are strings.
        case signal(String)
    }

    /// The terminal event of one id, and the error of a failed answer.
    struct Terminal: Sendable {
        /// The terminal event.
        let event: SessionEvent

        /// The error that ended a failed answer, or `nil`. `CancellationError`
        /// for a cancelled answer.
        let error: (any Error)?
    }

    /// The most ids that the ledger of the terminal events keeps.
    static let ledgerCapacity = 4096

    /// The readers and the ledger of the hub.
    private struct State {
        /// The feeds, by their key.
        var feeds: [ULID: AsyncStream<SessionOutput>.Continuation] = [:]

        /// The mail subscriptions, by their key, with the id of their mail.
        var subscriptions: [ULID: (id: MailID, continuation: AsyncStream<SessionOutput>.Continuation)] = [:]

        /// The terminal events of the most recent ids.
        var ledger: [TerminalKey: Terminal] = [:]

        /// The ids of ``ledger``, oldest first.
        var ledgerOrder: [TerminalKey] = []

        /// The waiters of ``SessionOutputHub/awaitTerminal(of:)``, by their
        /// key, with the id that each one waits for.
        var waiters: [ULID: (key: TerminalKey, continuation: CheckedContinuation<Terminal, any Error>)] = [:]

        /// Whether ``SessionOutputHub/close()`` ran.
        var isClosed = false

        /// The ids of the mail of the answers that ``RoutedSession/cancelAll()`` stopped
        /// (``SessionOutputHub/silence(_:)``).
        var silenced: Set<MailID> = []

        /// The ids of ``silenced``, oldest first.
        var silencedOrder: [MailID] = []

        /// Whether `origin` belongs to an answer that ``RoutedSession/cancelAll()`` stopped.
        ///
        /// - Parameter origin: The origin of one output.
        /// - Returns: `true` when the origin holds a silenced id.
        func isSilenced(_ origin: Origin) -> Bool {
            guard case .mail(let ids) = origin else { return false }
            return !ids.isDisjoint(with: silenced)
        }

        /// Records `terminal` for `key` in the ledger, and removes the oldest
        /// id when the ledger is full.
        ///
        /// - Parameters:
        ///   - terminal: The terminal event.
        ///   - key: The id that it ends.
        mutating func record(_ terminal: Terminal, for key: TerminalKey) {
            if ledger.updateValue(terminal, forKey: key) == nil {
                ledgerOrder.append(key)
            }
            guard ledgerOrder.count > SessionOutputHub.ledgerCapacity else { return }
            ledger.removeValue(forKey: ledgerOrder.removeFirst())
        }

        /// Removes and gives each waiter for `key`.
        ///
        /// - Parameter key: The id.
        /// - Returns: The waiters for `key`.
        mutating func takeWaiters(for key: TerminalKey) -> [CheckedContinuation<Terminal, any Error>] {
            let keys = waiters.filter { $0.value.key == key }.map(\.key)
            return keys.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
    }

    /// The state of the hub.
    private let state = Mutex(State())

    /// Makes a hub with no reader.
    init() {}

    /// Makes a feed that gets each output from now on, until ``finishFeeds()``
    /// or until its reader stops.
    ///
    /// - Returns: The output of the session.
    func makeFeed() -> AsyncStream<SessionOutput> {
        let key = ULID()
        let (stream, continuation) = AsyncStream.makeStream(of: SessionOutput.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.feeds.removeValue(forKey: key) }
        }
        state.withLock { $0.feeds[key] = continuation }
        return stream
    }

    /// Finishes each feed. A feed made later works as usual.
    func finishFeeds() {
        let feeds = state.withLock { state in
            defer { state.feeds = [:] }
            return Array(state.feeds.values)
        }
        for feed in feeds {
            feed.finish()
        }
    }

    /// Subscribes to the output of the mail `id`.
    ///
    /// - Parameter id: The id of the mail.
    /// - Returns: The subscription, and the key that ``unsubscribe(_:)``
    ///   takes.
    func subscribe(to id: MailID) -> (subscription: MailSubscription<SessionOutput>, key: ULID) {
        let key = ULID()
        let (stream, continuation) = AsyncStream.makeStream(of: SessionOutput.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscriptions.removeValue(forKey: key) }
        }
        state.withLock { $0.subscriptions[key] = (id, continuation) }
        return (MailSubscription(id: id, events: stream), key)
    }

    /// Finishes and removes one mail subscription, for example for mail
    /// that the session refused.
    ///
    /// - Parameter key: The key that ``subscribe(to:)`` gave.
    func unsubscribe(_ key: ULID) {
        state.withLock { $0.subscriptions.removeValue(forKey: key) }?.continuation.finish()
    }

    /// Gives `output` to each feed, and to each mail subscription whose mail
    /// it belongs to. A terminal event also finishes the subscriptions of the
    /// ids that it ends, records each id in the ledger, and ends the wait of
    /// each waiter for those ids.
    ///
    /// An output belongs to a mail when its origin holds the id of the mail,
    /// or when `audience` holds that id. The audience is the mail of the
    /// answer whose work sent the output. Thus an automatic compaction inside
    /// an answer, which has the origin of a signal of its own, also goes to
    /// the subscriptions of the mail of that answer.
    ///
    /// - Parameters:
    ///   - output: The output.
    ///   - error: The error that ended a failed answer, when `output` is its
    ///     ``SessionEvent/answerFailed(_:)``, or `nil`.
    ///   - audience: The mail of the answer whose work sent `output`, or no
    ///     mail (the default).
    /// - Returns: The ids that `output` ended, in the order of the event, or
    ///   none when `output` is no terminal event or when the hub dropped it.
    @discardableResult
    func emit(_ output: SessionOutput, failure error: (any Error)? = nil, audience: Set<MailID> = []) -> [TerminalKey] {
        let endedKeys = Self.keys(endedBy: output.event)
        let ended = Set(endedKeys)
        let terminal = Terminal(event: output.event, error: error)
        let (finished, resumed, isDelivered) = state.withLock {
            state -> ([AsyncStream<SessionOutput>.Continuation], [CheckedContinuation<Terminal, any Error>], Bool) in
            // The answer that ``RoutedSession/cancelAll()`` stopped already
            // has its terminal event: each later output of its work is
            // dropped, also its own end and the events of a compaction
            // inside it.
            guard !state.isSilenced(output.origin), audience.isDisjoint(with: state.silenced) else {
                return ([], [], false)
            }
            for feed in state.feeds.values {
                feed.yield(output)
            }
            var finished: [AsyncStream<SessionOutput>.Continuation] = []
            for (key, subscription) in state.subscriptions {
                let endsMail = ended.contains(.mail(subscription.id))
                let belongs = output.origin.contains(subscription.id) || audience.contains(subscription.id)
                guard endsMail || belongs else { continue }
                subscription.continuation.yield(output)
                if endsMail {
                    finished.append(subscription.continuation)
                    state.subscriptions.removeValue(forKey: key)
                }
            }
            var resumed: [CheckedContinuation<Terminal, any Error>] = []
            for key in ended {
                state.record(terminal, for: key)
                resumed += state.takeWaiters(for: key)
            }
            return (finished, resumed, true)
        }
        // A finish runs the termination handler of the stream, which takes
        // the lock. Thus each finish comes after the lock is released.
        for continuation in finished {
            continuation.finish()
        }
        for waiter in resumed {
            waiter.resume(returning: terminal)
        }
        return isDelivered ? endedKeys : []
    }

    /// Drops each later output whose origin holds an id of `ids`: the
    /// output of an answer that ``RoutedSession/cancelAll()`` stopped, after
    /// its terminal event. The work of that answer can run on for a time,
    /// because a stop is cooperative, but its readers get nothing more.
    ///
    /// The hub keeps at most ``ledgerCapacity`` silenced ids, and the oldest
    /// id leaves first. A run of a stopped answer is swept, so its late
    /// output comes soon after the stop.
    ///
    /// - Parameter ids: The ids of the mail of the stopped answer.
    func silence(_ ids: Set<MailID>) {
        state.withLock { state in
            for id in ids where state.silenced.insert(id).inserted {
                state.silencedOrder.append(id)
            }
            while state.silencedOrder.count > Self.ledgerCapacity {
                state.silenced.remove(state.silencedOrder.removeFirst())
            }
        }
    }

    /// The terminal event of `key` from the ledger, or `nil` when the ledger
    /// does not have it.
    ///
    /// - Parameter key: The id.
    /// - Returns: The terminal event and its error.
    func terminal(for key: TerminalKey) -> Terminal? {
        state.withLock { $0.ledger[key] }
    }

    /// Waits for the terminal event of `key`. Returns at once when the
    /// ledger has it.
    ///
    /// - Parameter key: The id.
    /// - Returns: The terminal event and its error.
    /// - Throws: `CancellationError` when the task is cancelled first, or
    ///   ``MailRefusal/closed`` when the hub closes first.
    func awaitTerminal(of key: TerminalKey) async throws -> Terminal {
        let waiterKey = ULID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediate = state.withLock { state -> Result<Terminal, any Error>? in
                    if let terminal = state.ledger[key] {
                        return .success(terminal)
                    }
                    if state.isClosed {
                        return .failure(MailRefusal.closed)
                    }
                    // A cancel that came before this registration found no
                    // waiter to end, so the registration reads it here.
                    if Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    state.waiters[waiterKey] = (key, continuation)
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: waiterKey) }?.continuation.resume(
                throwing: CancellationError())
        }
    }

    /// Closes the hub: each mail subscription finishes, and each waiter gets
    /// ``MailRefusal/closed``. A later wait for an id that the ledger does
    /// not have throws ``MailRefusal/closed`` at once.
    func close() {
        let (subscriptions, waiters) = state.withLock { state in
            state.isClosed = true
            defer {
                state.subscriptions = [:]
                state.waiters = [:]
            }
            return (state.subscriptions.values.map(\.continuation), state.waiters.values.map(\.continuation))
        }
        for subscription in subscriptions {
            subscription.finish()
        }
        for waiter in waiters {
            waiter.resume(throwing: MailRefusal.closed)
        }
    }

    /// The ids that `event` ends: the mail of an answer, a cancelled or lost
    /// mail, or a signal. The terminal events of a signal are
    /// ``SessionEvent/signalDone(_:)``, and for a compaction
    /// ``SessionEvent/compaction(_:)`` and ``SessionEvent/compactionFailed(_:)``.
    ///
    /// - Parameter event: One event of the session.
    /// - Returns: The ids, or none when the event is no terminal event.
    static func keys(endedBy event: SessionEvent) -> [TerminalKey] {
        switch event {
        case .answered(let answer):
            answer.mailIds.map(TerminalKey.mail)
        case .answerFailed(let failure):
            failure.mailIds.map(TerminalKey.mail)
        case .cancelled(let id), .lost(let id):
            [.mail(id)]
        case .signalDone(let id):
            [.signal(id.description)]
        case .compaction(let result):
            [.signal(result.id)]
        case .compactionFailed(let failure):
            [.signal(failure.id)]
        default:
            []
        }
    }
}
