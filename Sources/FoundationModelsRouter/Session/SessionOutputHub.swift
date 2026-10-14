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
/// - A waiter (``awaitTerminal(of:orThrow:)``) waits for the terminal event of one
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
/// and the oldest id leaves first. The ledger also keeps the error of a
/// failed answer next to its ``SessionEvent/answerFailed(_:)``: the helpers
/// on top of the core throw that error, and the public event does not carry
/// it.
///
/// The hub also keeps the pending ids: each id that waits for its terminal
/// event (``beginPending(_:)``). The session makes an id pending before any
/// caller can get it, and the terminal event of the id ends its pending
/// record under the same lock as the record of the ledger. Thus each id that
/// the session knows is pending, or in the ledger, or it left the ledger. A
/// wait for an id in neither set throws at once
/// (``awaitTerminal(of:orThrow:)``): no terminal event can come for it. The
/// pending set holds only the ids of the work that waits or runs, so it is
/// bounded by that work.
///
/// Each operation holds the lock of the hub and does not suspend, so a call
/// from any task, also a synchronous call that is not on the session actor,
/// reaches the hub at once.
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

        /// The answer of the mail that this terminal event ends, or the error
        /// that the caller of that mail gets.
        ///
        /// This is the one place that changes the terminal event of a mail
        /// into a thrown error. ``RoutedSession/awaitAnswer(of:)``,
        /// ``RoutedSession/respond(to:maxTokens:)`` and the stream helpers
        /// all use it.
        ///
        /// - Returns: The ``SessionAnswer`` of ``SessionEvent/answered(_:)``.
        ///   Each mail that one answer delivered gets that same answer.
        /// - Throws: For ``SessionEvent/answerFailed(_:)``, ``error``, or the
        ///   ``AnswerFailure`` of the event when the hub kept no error. For
        ///   ``SessionEvent/cancelled(_:)`` and ``SessionEvent/lost(_:)``,
        ///   `CancellationError`.
        func answer() throws -> SessionAnswer {
            switch event {
            case .answered(let answer):
                return answer
            case .answerFailed(let failure):
                throw error ?? failure
            case .cancelled, .lost:
                throw CancellationError()
            case .signalDone, .compaction, .compactionFailed, .compactionStarted, .submissionQueued,
                .submissionStarted, .submissionEnded, .textDelta, .textReset, .reasoningDelta, .entryRecorded,
                .discoveryPrimingFailed, .generationStalled, .runSettled, .runMessage, .runProgress, .toolCall,
                .toolStatus, .toolInvocation, .toolCallReport, .toolDisplay, .elicitationRequested, .generationCall,
                .repetitionStopped, .reasoningStopped, .mailDeliveryPaused, .mailDelivered:
                // The ledger keeps only a terminal event under the key of a
                // mail (``SessionOutputHub/keys(endedBy:)``), so a call with
                // another event is a defect of the caller.
                preconditionFailure("\(event) is no terminal event of a mail")
            }
        }
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

        /// The ids that wait for their terminal event
        /// (``SessionOutputHub/beginPending(_:)``).
        var pending: Set<TerminalKey> = []

        /// The waiters of ``SessionOutputHub/awaitTerminal(of:orThrow:)``, by
        /// their key.
        var waiters: [ULID: Waiter] = [:]

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

        /// Records `terminal` for `key` in the ledger, ends the pending record
        /// of `key`, and removes the oldest id when the ledger is full.
        ///
        /// The two changes come under one lock, so a wait never finds `key`
        /// in neither set while its terminal event goes in.
        ///
        /// - Parameters:
        ///   - terminal: The terminal event.
        ///   - key: The id that it ends.
        mutating func record(_ terminal: Terminal, for key: TerminalKey) {
            pending.remove(key)
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
        mutating func takeWaiters(for key: TerminalKey) -> [Waiter] {
            let keys = waiters.filter { $0.value.key == key }.map(\.key)
            return keys.compactMap { waiters.removeValue(forKey: $0) }
        }

        /// Registers `waiter` under `waiterKey`, or gives the result of a
        /// wait that ends at once.
        ///
        /// The checks come in this order: the ledger, the close, the pending
        /// ids, and the cancel of the task. Thus an id that is in no set gets
        /// the error of the waiter also from a cancelled task.
        ///
        /// - Parameters:
        ///   - waiter: The wait.
        ///   - waiterKey: The key of the wait.
        /// - Returns: The terminal event from the ledger,
        ///   ``MailRefusal/closed``, the error of an id that is not pending
        ///   (``SessionOutputHub/Waiter/unknown``), `CancellationError`, or `nil` when the
        ///   waiter now waits.
        mutating func register(_ waiter: Waiter, as waiterKey: ULID) -> Result<Terminal, any Error>? {
            if let terminal = ledger[waiter.key] {
                return .success(terminal)
            }
            if isClosed {
                return .failure(MailRefusal.closed)
            }
            // An id that is not pending gets no terminal event: it left the
            // ledger, or the session never knew it.
            guard pending.contains(waiter.key) else {
                return .failure(waiter.unknown)
            }
            // A cancel that came before this registration found no waiter
            // to end, so the registration reads it here.
            if Task.isCancelled {
                return .failure(CancellationError())
            }
            waiters[waiterKey] = waiter
            return nil
        }
    }

    /// One wait of ``awaitTerminal(of:orThrow:)``.
    private struct Waiter {
        /// The id that the wait waits for.
        let key: TerminalKey

        /// The error that ends the wait when the id leaves the pending ids
        /// with no terminal event (``endPending(_:)``).
        let unknown: any Error

        /// The continuation of the wait.
        let continuation: CheckedContinuation<Terminal, any Error>
    }

    /// The lock of the hub state, which counts each take of the lock.
    ///
    /// The state is reachable only through ``withLock(_:)``, so the count
    /// holds each take. Only the tests read the count: a test checks that
    /// a code path, for example the stop of a reader, does not take the
    /// lock.
    private struct StateLock: ~Copyable, Sendable {
        /// The lock and the state.
        private let mutex = Mutex(State())

        /// How many times the lock was taken.
        private let takes = Atomic(0)

        /// How many times the lock was taken.
        var takeCount: Int {
            takes.load(ordering: .relaxed)
        }

        /// Runs `body` on the state under the lock, and counts the take.
        ///
        /// - Parameter body: The work on the state.
        /// - Returns: What `body` returns.
        /// - Throws: What `body` throws.
        borrowing func withLock<Result: ~Copyable, Failure: Error>(
            _ body: (inout sending State) throws(Failure) -> sending Result
        ) throws(Failure) -> sending Result {
            takes.add(1, ordering: .relaxed)
            return try mutex.withLock(body)
        }
    }

    /// The state of the hub.
    private let state = StateLock()

    /// The keys of the feeds and the mail subscriptions whose readers
    /// stopped, which the hub did not remove yet.
    ///
    /// The termination handler of a feed or a subscription writes here, and
    /// only here. A stream runs that handler while it holds its own lock, and
    /// ``emit(_:failure:audience:)`` yields to a stream while it holds the
    /// lock of the hub. A handler that took the lock of the hub would take
    /// the two locks in the other order, and the two orders together cause a
    /// deadlock. This lock is always the last lock: no code takes another
    /// lock while it holds this one. Each operation of the hub on its readers
    /// removes these keys under the lock of the hub before it does its work
    /// (``withLiveReaders(_:)``). Thus a reader that stopped leaves the hub at
    /// the next operation of the hub, with no wait for the next output.
    private let stoppedReaders = Mutex<Set<ULID>>([])

    /// Reports each change of ``waiterCount``.
    ///
    /// The hub signals it after a wait of ``awaitTerminal(of:orThrow:)``
    /// starts to wait, and after waits stop: a cancel, a terminal event, an
    /// end of a pending id (``endPending(_:)``), or ``close()``. Each signal
    /// comes after the lock of the hub is released. Only the tests read it:
    /// a test waits on it until a task waits for a terminal event, and then
    /// checks that the wait did not return.
    let waiterChanges = ChangeSignal()

    /// How many waits of ``awaitTerminal(of:orThrow:)`` wait now.
    var waiterCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// How many feeds and mail subscriptions the hub holds now. Only the tests
    /// read it: a test checks that a reader that stopped left the hub.
    var readerCount: Int {
        withLiveReaders { $0.feeds.count + $0.subscriptions.count }
    }

    /// How many times the lock of the hub state was taken. Only the tests read
    /// it: a test checks that a reader that stops does not take the lock.
    var stateLockTakes: Int {
        state.takeCount
    }

    /// Makes a hub with no reader.
    init() {}

    /// Runs `body` on the state of the hub under its lock, after it removes
    /// each feed and each mail subscription whose reader stopped
    /// (``stoppedReaders``).
    ///
    /// - Parameter body: The work on the state.
    /// - Returns: What `body` returns.
    private func withLiveReaders<Value: Sendable>(_ body: (inout State) -> Value) -> Value {
        state.withLock { state in
            let stopped = stoppedReaders.withLock { keys in
                defer { keys = [] }
                return keys
            }
            for key in stopped {
                state.feeds[key] = nil
                state.subscriptions[key] = nil
            }
            return body(&state)
        }
    }

    /// Makes a stream for one reader, whose termination handler records `key`
    /// in ``stoppedReaders`` when the reader stops or the stream finishes.
    ///
    /// The handler is set before the hub records the reader, and the stream
    /// is not given to the reader before that record. Thus a key of a stopped
    /// reader is never removed before the hub records it.
    ///
    /// - Parameter key: The key of the reader.
    /// - Returns: The stream and its continuation.
    private func makeReaderStream(
        key: ULID
    ) -> (stream: AsyncStream<SessionOutput>, continuation: AsyncStream<SessionOutput>.Continuation) {
        let (stream, continuation) = AsyncStream.makeStream(of: SessionOutput.self, bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in
            self?.stoppedReaders.withLock { _ = $0.insert(key) }
        }
        return (stream, continuation)
    }

    /// Makes a feed that gets each output from now on, until ``finishFeeds()``
    /// or until its reader stops.
    ///
    /// - Returns: The output of the session.
    func makeFeed() -> AsyncStream<SessionOutput> {
        let key = ULID()
        let (stream, continuation) = makeReaderStream(key: key)
        withLiveReaders { $0.feeds[key] = continuation }
        return stream
    }

    /// Finishes each feed. A feed made later works as usual.
    func finishFeeds() {
        let feeds = withLiveReaders { state in
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
        let (stream, continuation) = makeReaderStream(key: key)
        withLiveReaders { $0.subscriptions[key] = (id, continuation) }
        return (MailSubscription(id: id, events: stream), key)
    }

    /// Finishes and removes one mail subscription, for example for mail
    /// that the session refused.
    ///
    /// - Parameter key: The key that ``subscribe(to:)`` gave.
    func unsubscribe(_ key: ULID) {
        withLiveReaders { $0.subscriptions.removeValue(forKey: key) }?.continuation.finish()
    }

    /// Gives `output` to each feed, and to each mail subscription whose mail
    /// it belongs to. A terminal event also finishes the subscriptions of the
    /// ids that it ends, records each id in the ledger, ends the pending
    /// record of each id, and ends the wait of each waiter for those ids.
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
        let (finished, resumed, isDelivered) = withLiveReaders {
            state -> ([AsyncStream<SessionOutput>.Continuation], [CheckedContinuation<Terminal, any Error>], Bool) in
            // The answer that ``RoutedSession/cancelAll()`` stopped already
            // has its terminal event: each later output of its work is
            // dropped, also its own end and the events of a compaction
            // inside it.
            guard !state.isSilenced(output.origin), audience.isDisjoint(with: state.silenced) else {
                return ([], [], false)
            }
            for (key, feed) in state.feeds {
                if case .terminated = feed.yield(output) {
                    state.feeds.removeValue(forKey: key)
                }
            }
            var finished: [AsyncStream<SessionOutput>.Continuation] = []
            for (key, subscription) in state.subscriptions {
                let endsMail = ended.contains(.mail(subscription.id))
                let belongs = output.origin.contains(subscription.id) || audience.contains(subscription.id)
                guard endsMail || belongs else { continue }
                if case .terminated = subscription.continuation.yield(output) {
                    state.subscriptions.removeValue(forKey: key)
                    continue
                }
                if endsMail {
                    finished.append(subscription.continuation)
                    state.subscriptions.removeValue(forKey: key)
                }
            }
            var resumed: [CheckedContinuation<Terminal, any Error>] = []
            for key in ended {
                state.record(terminal, for: key)
                resumed += state.takeWaiters(for: key).map(\.continuation)
            }
            return (finished, resumed, true)
        }
        // A finish takes the lock of the stream, and a reader that stops can
        // hold that lock. Thus each finish comes after the lock of the hub is
        // released.
        for continuation in finished {
            continuation.finish()
        }
        for waiter in resumed {
            waiter.resume(returning: terminal)
        }
        if !resumed.isEmpty {
            waiterChanges.signal()
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

    /// Whether the hub drops each output whose origin is `origin`: the
    /// origin holds the mail of an answer that ``RoutedSession/cancelAll()``
    /// stopped (``silence(_:)``).
    ///
    /// - Parameter origin: The origin of one output.
    /// - Returns: `true` when the origin holds a silenced id.
    func drops(_ origin: Origin) -> Bool {
        state.withLock { $0.isSilenced(origin) }
    }

    /// The terminal event of `key` from the ledger, or `nil` when the ledger
    /// does not have it.
    ///
    /// - Parameter key: The id.
    /// - Returns: The terminal event and its error.
    func terminal(for key: TerminalKey) -> Terminal? {
        state.withLock { $0.ledger[key] }
    }

    /// Records that `key` waits for its terminal event: a wait for `key`
    /// waits, and does not throw the error of an unknown id. The terminal
    /// event of `key` ends the record (``emit(_:failure:audience:)``), and
    /// so does ``endPending(_:)``.
    ///
    /// The session calls it before any caller can get the id: before the put
    /// of mail into the queue, and before a signal call returns its id.
    /// After ``close()`` the hub records nothing, because each wait then
    /// throws ``MailRefusal/closed``.
    ///
    /// - Parameter key: The id.
    /// - Returns: `true` when this call made `key` pending, and `false` when
    ///   `key` was pending already or the hub is closed. Only the call that
    ///   made `key` pending ends it with ``endPending(_:)``.
    @discardableResult
    func beginPending(_ key: TerminalKey) -> Bool {
        state.withLock { state in
            guard !state.isClosed else { return false }
            return state.pending.insert(key).inserted
        }
    }

    /// Ends the pending record of `key` with no terminal event: the session
    /// refused the mail, or the work of the signal ended and sent no terminal
    /// event. No terminal event comes for `key` any more, so each wait for it
    /// ends with the error that the wait gave (``Waiter/unknown``), and a
    /// later wait throws that error at once.
    ///
    /// A `key` that is not pending, or whose terminal event is in the
    /// ledger, does not change.
    ///
    /// - Parameter key: The id.
    func endPending(_ key: TerminalKey) {
        let ended = state.withLock { state -> [Waiter] in
            guard state.pending.remove(key) != nil, state.ledger[key] == nil else { return [] }
            return state.takeWaiters(for: key)
        }
        for waiter in ended {
            waiter.continuation.resume(throwing: waiter.unknown)
        }
        if !ended.isEmpty {
            waiterChanges.signal()
        }
    }

    /// Waits for the terminal event of `key`. Returns at once when the
    /// ledger has it. Throws `unknown` at once when `key` is not pending
    /// (``beginPending(_:)``) and the ledger does not have it: `key` left the
    /// ledger, or the session never knew it, so no terminal event can come.
    ///
    /// The check and the registration of the wait hold the lock of the hub,
    /// and so does the terminal event that ends the pending record of `key`
    /// and records it in the ledger. Thus the wait never finds `key` in
    /// neither set while its terminal event goes in.
    ///
    /// - Parameters:
    ///   - key: The id.
    ///   - unknown: The error for a `key` that is not pending and not in the
    ///     ledger.
    /// - Returns: The terminal event and its error.
    /// - Throws: `unknown`, `CancellationError` when the task is cancelled
    ///   first, or ``MailRefusal/closed`` when the hub closes first.
    func awaitTerminal(of key: TerminalKey, orThrow unknown: any Error) async throws -> Terminal {
        let waiterKey = ULID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = Waiter(key: key, unknown: unknown, continuation: continuation)
                if let immediate = state.withLock({ $0.register(waiter, as: waiterKey) }) {
                    continuation.resume(with: immediate)
                } else {
                    waiterChanges.signal()
                }
            }
        } onCancel: {
            guard let waiter = state.withLock({ $0.waiters.removeValue(forKey: waiterKey) }) else { return }
            waiter.continuation.resume(throwing: CancellationError())
            waiterChanges.signal()
        }
    }

    /// Closes the hub: each mail subscription finishes, and each waiter gets
    /// ``MailRefusal/closed``. A later wait for an id that the ledger does
    /// not have throws ``MailRefusal/closed`` at once, so the hub also
    /// forgets the pending ids.
    func close() {
        let (subscriptions, waiters) = withLiveReaders { state in
            state.isClosed = true
            defer {
                state.subscriptions = [:]
                state.waiters = [:]
                state.pending = []
            }
            return (state.subscriptions.values.map(\.continuation), state.waiters.values.map(\.continuation))
        }
        for subscription in subscriptions {
            subscription.finish()
        }
        for waiter in waiters {
            waiter.resume(throwing: MailRefusal.closed)
        }
        if !waiters.isEmpty {
            waiterChanges.signal()
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
