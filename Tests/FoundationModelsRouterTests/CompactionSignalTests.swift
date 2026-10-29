import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises the compaction signal (`mailbox.md`, section 3, and section 5,
/// "Decision: signals run one at a time, in order").
///
/// ``RoutedSession/compact(prompt:budget:)`` returns its ``SignalID`` at
/// once. The compaction runs in the order of the signals: it pauses the mail
/// queue, sends ``SessionEvent/compactionStarted(_:)``, and ends with
/// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``,
/// the terminal event of the signal. An automatic compaction of an answer
/// runs the same handler, with a signal id of its own.
///
/// The tests use the stubs of ``AnswerCancellationTests``: the flash slot and
/// the standard slot load the same hooked container, so each summarizer call
/// of each tier goes through the hook of the test. No network and no GPU.
@Suite("The compaction signal")
struct CompactionSignalTests {
    /// The fixtures and the stubs of the suite.
    private typealias Fixtures = AnswerCancellationTests

    /// The prompt of a message that a test sends while a compaction runs.
    private static let waitingPrompt = "waits for the compaction"

    /// The prompt of a message that a test sends after the signals ended.
    private static let laterPrompt = "after the signals"

    // MARK: - The output log

    /// Collects the output of the feed of one session
    /// (``RoutedSession/streamSessionEvents()``), with the origin of each
    /// event, so a test reads the order and the origins.
    private actor OutputLog {
        /// Each output so far, in delivery order.
        private(set) var outputs: [SessionOutput] = []

        /// Appends one output.
        ///
        /// - Parameter output: The output that the feed gave.
        func append(_ output: SessionOutput) {
            outputs.append(output)
        }

        /// The events of the outputs, in delivery order.
        var events: [SessionEvent] {
            outputs.map(\.event)
        }

        /// The place of the first event that `matches` accepts, or `nil`.
        ///
        /// - Parameter matches: The test of one event.
        /// - Returns: The index of the event in ``outputs``.
        func firstIndex(where matches: @Sendable (SessionEvent) -> Bool) -> Int? {
            firstPosition(in: outputs, where: matches)
        }

        /// The output of the first event that `matches` accepts, or `nil`.
        ///
        /// - Parameter matches: The test of one event.
        /// - Returns: The output.
        func first(where matches: @Sendable (SessionEvent) -> Bool) -> SessionOutput? {
            outputs.first { matches($0.event) }
        }

        /// Subscribes to the feed of `session` and drains it into a new log.
        ///
        /// - Parameter session: The session to watch.
        /// - Returns: The log, and the task that drains the feed. The task
        ///   ends when the feed finishes.
        static func watch(_ session: any RoutedSession) async -> (log: OutputLog, drain: Task<Void, Never>) {
            let log = OutputLog()
            let feed = await session.streamSessionEvents()
            let drain = Task {
                for await output in feed {
                    await log.append(output)
                }
            }
            return (log, drain)
        }
    }

    // MARK: - Fixtures

    /// A flag that one task sets and another task reads.
    private final class Flag: Sendable {
        /// Whether the flag is set.
        private let state = Mutex(false)

        /// Sets the flag.
        func set() {
            state.withLock { $0 = true }
        }

        /// Whether the flag is set.
        var isSet: Bool {
            state.withLock { $0 }
        }
    }

    /// The id of a signal that one task sends and another task reads.
    private final class SignalSlot: Sendable {
        /// The id, or `nil` before a task sent the signal.
        private let state = Mutex<SignalID?>(nil)

        /// Keeps the id of the signal that a task sent.
        ///
        /// - Parameter id: The id of the signal.
        func keep(_ id: SignalID) {
            state.withLock { $0 = id }
        }

        /// The id of the signal, or `nil` before a task sent it.
        var id: SignalID? {
            state.withLock { $0 }
        }
    }

    /// The gates of a test where the work of a compaction reaches the session
    /// after close began. The answer of ``heldPrompt`` holds its model call,
    /// and each summarizer call holds, until the test opens the gate. No
    /// cancel ends a hold, so only the test releases them.
    private final class LateCompactionGates: Sendable {
        /// Signalled when the answer holds its model call.
        let answerInside = AsyncSemaphore(value: 0)

        /// Lets the answer go on.
        let answerRelease = AsyncSemaphore(value: 0)

        /// Signalled when a summarizer call starts, and when the work of the
        /// compaction ends: the first of the two tells the test which came.
        let progress = AsyncSemaphore(value: 0)

        /// Lets a summarizer call go on.
        let summarizerRelease = AsyncSemaphore(value: 0)

        /// Set when a summarizer call started: a compaction started.
        let summarizerStarted = Flag()

        /// Set when a summarizer call saw a cancel at the end of its hold.
        let summarizerSawCancel = Flag()

        /// Holds the model call that carries `prompt` when it is a summarizer
        /// call or the call of the answer of ``heldPrompt``. Other calls go on.
        ///
        /// - Parameter prompt: The prompt of the model call.
        func hold(_ prompt: String) async {
            if Fixtures.isSummarizerCall(prompt) {
                await holdSummarizerCall()
            } else if prompt.hasSuffix(CompactionSignalTests.heldPrompt) {
                answerInside.signal()
                await answerRelease.wait()
            }
        }

        /// Holds one summarizer call until ``summarizerRelease``, and records
        /// whether the call saw a cancel.
        private func holdSummarizerCall() async {
            summarizerStarted.set()
            progress.signal()
            await summarizerRelease.wait()
            if Task.isCancelled {
                summarizerSawCancel.set()
            }
        }
    }

    /// The prompt of a message whose answer holds its model call while close
    /// runs, so the drain of close waits for the pump.
    private static let heldPrompt = "holds its model call during close"

    /// Makes each summarizer call of `fixture` reply with a short summary.
    ///
    /// The stub backend replies with "ok-" and the full prompt. That summary
    /// does not make the context smaller, so the compaction applies nothing.
    /// A short summary makes the context smaller, so the compaction applies
    /// its summary and names the tier that wrote it.
    ///
    /// - Parameter fixture: The fixture whose hook gets the reply.
    private static func replyWithShortSummary(_ fixture: Fixtures.Fixture) {
        fixture.hook.reply = { Fixtures.isSummarizerCall($0) ? "short summary" : nil }
    }

    /// A warmed-up session whose next answer does not compact by itself,
    /// with the fixture behind it. Each summarizer call replies with a short
    /// summary, so a compaction applies.
    ///
    /// - Parameter dir: The cache directory of the router.
    /// - Returns: The fixture and the session.
    /// - Throws: What the warm-up throws.
    private static func makeSession(dir: URL) async throws -> (Fixtures.Fixture, any RoutedSession) {
        let fixture = try await Fixtures.makeFixture(cacheDir: dir)
        replyWithShortSummary(fixture)
        let session = try await Fixtures.makeCompactionTriggeredSession(
            fixture, budget: Fixtures.summarizingCompactionBudget, metersTriggeringFill: false)
        return (fixture, session)
    }

    /// Holds the first summarizer call inside the hook until `release` is
    /// signalled. The hold does not stop on a cancel, so only `release` ends
    /// it. The hook records whether the call saw a cancel when it ended.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - inside: Signalled when the summarizer call is inside the hook.
    ///   - release: The signal that lets the summarizer call go on.
    ///   - sawCancel: Set when the call saw a cancel at the end of the hold.
    private static func holdFirstSummarizerCall(
        _ fixture: Fixtures.Fixture, inside: AsyncSemaphore, release: AsyncSemaphore, sawCancel: Flag = Flag()
    ) {
        let isFirst = Fixtures.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard isFirst(prompt) else { return }
            inside.signal()
            await release.wait()
            if Task.isCancelled {
                sawCancel.set()
            }
        }
    }

    /// Holds the first summarizer call inside the hook until a cancel comes.
    /// Only ``RoutedSession/close()`` cancels a compaction, so the cancel
    /// comes while close runs. Then the hook sends one more compaction to
    /// `session`, keeps its id in `sentDuringClose`, and throws the cancel.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - session: The session that gets the compaction during close.
    ///   - inside: Signalled when the summarizer call is inside the hook.
    ///   - sentDuringClose: Gets the id of the compaction sent during close.
    private static func sendACompactionWhenCloseCancels(
        _ fixture: Fixtures.Fixture, session: any RoutedSession, inside: AsyncSemaphore, sentDuringClose: SignalSlot
    ) {
        let isFirst = Fixtures.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard isFirst(prompt) else { return }
            let cancelled = AsyncSemaphore(value: 0)
            await withTaskCancellationHandler {
                inside.signal()
                await cancelled.wait()
            } onCancel: {
                cancelled.signal()
            }
            sentDuringClose.keep(Fixtures.requestSummarizingCompaction(of: session))
            throw CancellationError()
        }
    }

    /// The terminal event of `id` in the ledger of the output of `session`,
    /// or `nil` when the signal did not end yet.
    ///
    /// - Parameters:
    ///   - id: The id of the signal.
    ///   - session: The session that got the signal.
    /// - Returns: The terminal event, or `nil`.
    private static func recordedTerminal(of id: SignalID, on session: any RoutedSession) throws -> SessionEvent? {
        let actor = try #require(session as? RoutedSessionActor)
        return actor.outputHub.terminal(for: .signal(id.description))?.event
    }

    /// Whether `event` is a terminal event of the compaction `id`.
    ///
    /// - Parameters:
    ///   - event: One event.
    ///   - id: The id of the compaction signal.
    /// - Returns: `true` for its ``SessionEvent/compaction(_:)`` or
    ///   ``SessionEvent/compactionFailed(_:)``.
    private static func endsCompaction(_ event: SessionEvent, _ id: SignalID) -> Bool {
        switch event {
        case .compaction(let result): result.id == id.description
        case .compactionFailed(let failure): failure.id == id.description
        default: false
        }
    }

    /// Whether `event` is the ``SessionEvent/compactionStarted(_:)`` of `id`.
    ///
    /// - Parameters:
    ///   - event: One event.
    ///   - id: The id of the compaction signal.
    /// - Returns: `true` for the start of that compaction.
    private static func startsCompaction(_ event: SessionEvent, _ id: SignalID) -> Bool {
        guard case .compactionStarted(let start) = event else { return false }
        return start.id == id.description
    }

    /// Waits until a hook signals `inside`, or until `terminal` returns (rule
    /// T1). When `terminal` returned first, the wait throws ``FailureEventCameFirst``.
    ///
    /// The work of the hook holds until the test opens its gate, so in a test
    /// that passes the terminal event comes only after `inside`. A work that
    /// ends before its hold, for example with an error, gives its terminal
    /// event, and the wait then ends. See
    /// ``RecordedWaitResult/wait(forPermitOf:endingOnEndOf:sourceLocation:)``.
    ///
    /// - Parameters:
    ///   - inside: The semaphore that the hook signals when the work holds.
    ///   - terminal: Waits for the terminal event of the work.
    ///   - sourceLocation: The place of the call, for the failure.
    /// - Throws: ``FailureEventCameFirst`` when the terminal event came first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    private static func waitForTheHold(
        _ inside: AsyncSemaphore,
        endingOn terminal: @escaping @Sendable () async throws -> SessionEvent,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let ending = Task { _ = try? await terminal() }
        defer { ending.cancel() }
        try await RecordedWaitResult.wait(forPermitOf: inside, endingOnEndOf: ending, sourceLocation: sourceLocation)
    }

    // MARK: - The id and the terminal event

    /// The production change that makes this test fail: a `compact` that
    /// waits for the work, or a terminal event that the ledger of the output
    /// does not keep.
    @Test("compact returns its SignalID at once, and its terminal event comes through awaitTerminal, also after the end")
    func compactReturnsItsSignalAtOnce() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let inside = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        Self.holdFirstSummarizerCall(fixture, inside: inside, release: release)
        defer {
            release.signal()
            await session.close()
        }

        // The call is synchronous: the id comes back while the summarizer
        // call is still held.
        let id = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: id) })
        #expect(try Self.recordedTerminal(of: id, on: session) == nil)

        release.signal()
        let terminal = try await session.awaitTerminal(of: id)
        guard case .compaction(let result) = terminal else {
            Issue.record("expected the compaction to complete, got \(terminal)")
            return
        }
        #expect(result.id == id.description)
        #expect(result.summaryEntryId != nil)

        // A wait after the end gets the same terminal event from the ledger.
        #expect(try await session.awaitTerminal(of: id) == terminal)
    }

    /// The production change that makes this test fail: a compaction that
    /// makes an id of its own in place of the id of its signal.
    @Test("the ids of compactionStarted and compaction are the SignalID of the compaction")
    func theEventsOfACompactionCarryItsSignalID() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, session) = try await Self.makeSession(dir: dir)
        defer { await session.close() }
        let (log, drain) = await OutputLog.watch(session)

        let id = Fixtures.requestSummarizingCompaction(of: session)
        _ = try await session.awaitTerminal(of: id)
        await session.close()
        await drain.value

        let events = await log.events
        #expect(events.compactionStarts.map(\.id) == [id.description])
        #expect(events.compactionStarts.map(\.reason) == [.requested])
        #expect(events.compactionResults.map(\.id) == [id.description])
        #expect(events.compactionLifecycleIsOrdered)
        TerminalEventLedger(events: events).expectExactlyOneTerminal(forSignals: [id])
        // The events of the compaction have the origin of its signal.
        let start = try #require(await log.first { Self.startsCompaction($0, id) })
        let end = try #require(await log.first { Self.endsCompaction($0, id) })
        #expect(start.origin == .signal(id))
        #expect(end.origin == .signal(id))
    }

    /// The production change that makes this test fail: a failure that
    /// makes an id of its own in place of the id of its signal.
    @Test("the id of compactionFailed is the SignalID of the compaction")
    func theFailureOfACompactionCarriesItsSignalID() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        defer { await session.close() }
        fixture.hook.midAnswer = { prompt in
            guard Fixtures.isSummarizerCall(prompt) else { return }
            throw Fixtures.ProbeError.summarizerFailed
        }

        let id = Fixtures.requestSummarizingCompaction(of: session)
        let terminal = try await session.awaitTerminal(of: id)

        let expected = CompactionFailure(
            id: id.description, reason: .requested,
            outcome: .failed(String(describing: Fixtures.ProbeError.summarizerFailed)))
        #expect(terminal == .compactionFailed(expected))
    }

    // MARK: - The pause of the mail queue

    /// The production change that makes this test fail: a compaction that
    /// does not pause the mail queue, or that does not wake the pump when it
    /// ends.
    @Test("mail that arrives during a compaction waits in the queue, and the session answers it after the compaction")
    func mailWaitsForTheCompaction() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let (log, drain) = await OutputLog.watch(session)
        let inside = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        Self.holdFirstSummarizerCall(fixture, inside: inside, release: release)
        defer {
            release.signal()
            await session.close()
        }

        let id = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: id) })
        let mailID = try session.send(Self.waitingPrompt)

        // The mail woke the pump, and the pump took nothing: the pump ends,
        // and the mail still waits in the queue.
        #expect(await session.isIdleOnceThePumpEnds() == false)
        #expect(session.outbox.queue.pending.map(\.id) == [mailID])
        #expect(await fixture.observer.entered.contains(Self.waitingPrompt) == false)

        release.signal()
        _ = try await session.awaitTerminal(of: id)
        let answer = try await session.awaitTerminal(of: mailID)
        #expect([answer].answers.map(\.mailIds) == [[mailID]])
        await session.close()
        await drain.value

        let compactionEnd = try #require(await log.firstIndex { Self.endsCompaction($0, id) })
        let delivery = try #require(await log.firstIndex { $0 == .mailDelivered(mailID) })
        #expect(compactionEnd < delivery)
    }

    // MARK: - cancelAll and close

    /// The production change that makes this test fail: a cancelAll that
    /// stops the running compaction, that drops its output, that runs out
    /// of the order of the signals, or that resumes the mail queue.
    @Test("a cancelAll during a compaction returns at once and runs after the compaction ended normally")
    func cancelAllRunsAfterTheRunningCompaction() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let (log, drain) = await OutputLog.watch(session)
        let inside = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        let sawCancel = Flag()
        Self.holdFirstSummarizerCall(fixture, inside: inside, release: release, sawCancel: sawCancel)
        defer {
            release.signal()
            await session.close()
        }

        let compactID = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: compactID) })
        let mailID = try session.send(Self.waitingPrompt)
        let cancelID = session.cancelAll()

        // The signal waits behind the compaction: it did no work yet, so the
        // mail is still in the queue.
        #expect(try Self.recordedTerminal(of: cancelID, on: session) == nil)
        #expect(session.outbox.queue.pending.map(\.id) == [mailID])

        release.signal()
        let compactionEnd = try await session.awaitTerminal(of: compactID)
        guard case .compaction = compactionEnd else {
            Issue.record("expected the compaction to complete, got \(compactionEnd)")
            return
        }
        #expect(try await session.awaitTerminal(of: cancelID) == .signalDone(cancelID))
        #expect(try await session.awaitTerminal(of: mailID) == .cancelled(mailID))
        #expect(sawCancel.isSet == false)

        // The queue is not paused after the signals: a later message is
        // answered.
        #expect(try await session.respond(to: Self.laterPrompt) == "ok-\(Self.laterPrompt)")
        await session.close()
        await drain.value

        let end = try #require(await log.first { Self.endsCompaction($0, compactID) })
        #expect(end.origin == .signal(compactID))
        let endIndex = try #require(await log.firstIndex { Self.endsCompaction($0, compactID) })
        let cancelledIndex = try #require(await log.firstIndex { $0 == .cancelled(mailID) })
        let doneIndex = try #require(await log.firstIndex { $0 == .signalDone(cancelID) })
        #expect(endIndex < cancelledIndex)
        #expect(cancelledIndex < doneIndex)
    }

    /// The production change that makes this test fail: a close that waits
    /// in the order of the signals, that waits for the summarizer, that
    /// finishes the feeds before the terminal event of the compaction, or
    /// that applies a compaction it cancelled.
    @Test("close during a compaction cancels the summarizer call, and compactionFailed comes before the feeds finish")
    func closeCancelsTheRunningCompaction() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let (log, drain) = await OutputLog.watch(session)
        let inside = AsyncSemaphore(value: 0)
        let sawCancellation = Fixtures.suspendInsideCancellationAwareTool(
            fixture, suspendingOn: Fixtures.firstSummarizerCall(), insideTool: inside)
        defer { await session.close() }
        let transcriptBefore = Array(await session.transcript)
        let recordedBefore = await fixture.recorder.events.count

        let id = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: id) })
        // The summarizer call ends only on a cancel, so close returns only
        // when it cancels the call. The close waits for the end of the
        // compaction, and the tool sends its event before that end, so the
        // wait also ends on the end of the close (rule T1).
        let closing = Task { await session.close() }
        defer { closing.cancel() }
        try await RecordedWaitResult.wait(for: sawCancellation, endingOnEndOf: closing)
        await closing.value
        await drain.value

        let expected = CompactionFailure(id: id.description, reason: .requested, outcome: .cancelled)
        #expect(await log.events.compactionFailures == [expected])
        #expect(await log.events.compactionResults.isEmpty)
        let failure = try #require(await log.first { Self.endsCompaction($0, id) })
        #expect(failure.origin == .signal(id))
        // Nothing of the compaction applied: the transcript of the session
        // and the record are as they were. The flash tier vends a new backend
        // from the same container during the compaction, so the test reads
        // the transcript of the session, not the last backend of the
        // container.
        #expect(Array(await session.transcript) == transcriptBefore)
        #expect(await fixture.recorder.events.count == recordedBefore)
    }

    /// The production change that makes this test fail: a signal that runs
    /// its work after close, or a close that cancels the running compaction
    /// before it closes the signal executor. A compaction that waits behind
    /// the running one, or that a caller sends while close cancels the
    /// running one, then starts after the cancel, and close waits for it.
    @Test("close cancels the running compaction, and a compaction sent before or during close does not start")
    func noCompactionStartsAfterCloseCancelledTheRunningOne() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let (log, drain) = await OutputLog.watch(session)
        let inside = AsyncSemaphore(value: 0)
        let sentDuringClose = SignalSlot()
        Self.sendACompactionWhenCloseCancels(
            fixture, session: session, inside: inside, sentDuringClose: sentDuringClose)
        defer { await session.close() }

        let running = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: running) })
        let waiting = Fixtures.requestSummarizingCompaction(of: session)
        // The summarizer call ends only on a cancel, so close returns only
        // when it cancels the running compaction.
        await session.close()
        await drain.value
        fixture.hook.midAnswer = nil

        // The running compaction ended with its terminal event before the
        // feeds finished. No other compaction started.
        let cancelled = CompactionFailure(id: running.description, reason: .requested, outcome: .cancelled)
        #expect(await log.events.compactionStarts.map(\.id) == [running.description])
        #expect(await log.events.compactionFailures == [cancelled])
        #expect(await log.events.compactionResults.isEmpty)
        let duringClose = try #require(sentDuringClose.id)
        for late in [waiting, duringClose] {
            await #expect(throws: MailRefusal.closed) {
                try await session.awaitTerminal(of: late)
            }
        }
        // Only the running compaction made a summarizer call.
        #expect(await fixture.observer.entered.filter(Fixtures.isSummarizerCall).count == 1)
    }

    /// The production change that makes this test fail: a signal entry
    /// (``RoutedSessionActor/runSignalWork(_:skipped:)``) that does not
    /// check, on the session, whether close began. The task of a compaction
    /// signal reads the close of the signal executor before it goes to the
    /// session, so its work can reach the session after close began. That
    /// compaction then starts: close does not cancel it, its events come
    /// after the feeds finished, and the drain of close waits for it. With a
    /// summarizer call that ends only on a cancel, close does not return.
    @Test("the work of a compaction signal that reaches the session after close began does not start")
    func aCompactionDoesNotStartAfterCloseBegan() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let gates = LateCompactionGates()
        // The drain of close waits for the held calls, so the deferred close
        // first opens each gate. A second signal does no harm.
        defer {
            gates.summarizerRelease.signal()
            gates.answerRelease.signal()
            await session.close()
        }
        let actor = try #require(session as? RoutedSessionActor)
        let (log, drain) = await OutputLog.watch(session)
        fixture.hook.midAnswer = { prompt in await gates.hold(prompt) }

        // The answer holds its model call, and the cancel of close does not
        // end the hold, so the drain of close waits for the pump until the
        // test releases the answer.
        let heldMail = try session.send(Self.heldPrompt)
        try await Self.waitForTheHold(gates.answerInside, endingOn: { try await session.awaitTerminal(of: heldMail) })
        let closing = Task { await session.close() }
        // Close finishes the feeds after it began and before its drain.
        await drain.value

        // The task of a compaction signal that read the executor before close
        // closed it: its work reaches the session now, after close began.
        let id = SignalID()
        let order = CompactionOrder(
            prompt: Fixtures.compactionSummarizerPrompt, budget: Fixtures.summarizingCompactionBudget,
            reason: .requested, overflowRetryTarget: nil)
        let skipped = Flag()
        let work = Task {
            await actor.runSignalWork(
                { session in _ = await session.performCompaction(id, order) },
                skipped: { skipped.set() })
            gates.progress.signal()
        }
        // The first of the two: a summarizer call of a compaction that
        // started, or the end of the work. The work signals before it ends,
        // so the wait also ends on the end of the work (rule T1).
        try await RecordedWaitResult.wait(forPermitOf: gates.progress, endingOnEndOf: work)
        let started = gates.summarizerStarted.isSet
        // The gates open in each case, so the test always ends.
        gates.summarizerRelease.signal()
        gates.answerRelease.signal()
        await work.value
        await closing.value
        fixture.hook.midAnswer = nil

        #expect(started == false)
        // Close cancels each compaction that starts. A compaction with no
        // cancel makes the drain of close wait for its summarizer call.
        #expect(started == gates.summarizerSawCancel.isSet)
        #expect(skipped.isSet)
        #expect(await log.firstIndex { Self.startsCompaction($0, id) } == nil)
        #expect(try Self.recordedTerminal(of: id, on: session) == nil)
        #expect(await fixture.observer.entered.filter(Fixtures.isSummarizerCall).isEmpty)
    }

    /// The production change that makes this test fail: a cancelAll that
    /// leaves the signals or the queue in a state that refuses later work.
    @Test("after cancelAll, a compaction, a cancel, a replace and close work as usual")
    func signalsWorkAfterCancelAll() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, session) = try await Self.makeSession(dir: dir)
        defer { await session.close() }

        let stop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stop) == .signalDone(stop))

        let compactID = Fixtures.requestSummarizingCompaction(of: session)
        guard case .compaction = try await session.awaitTerminal(of: compactID) else {
            Issue.record("expected the compaction after cancelAll to complete")
            return
        }
        let cancelID = session.cancel(MailID())
        #expect(try await session.awaitTerminal(of: cancelID) == .signalDone(cancelID))
        let replaceID = session.replace(MailID(), with: .userMessage(prompt: Self.laterPrompt, options: .init()))
        #expect(try await session.awaitTerminal(of: replaceID) == .signalDone(replaceID))
        #expect(try await session.respond(to: Self.laterPrompt) == "ok-\(Self.laterPrompt)")
    }

    // MARK: - One path for both kinds

    /// The production change that makes this test fail: an automatic
    /// compaction that does not run through the signal handler (no signal
    /// origin, no ledger entry), or an answer that does not go on after it.
    @Test("an automatic compaction runs the same handler with a SignalID of its own, and the answer goes on")
    func anAutomaticCompactionIsASignal() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = try await Fixtures.makeFixture(cacheDir: dir)
        Self.replyWithShortSummary(fixture)
        let session = try await Fixtures.makeCompactionTriggeredSession(
            fixture, budget: Fixtures.summarizingCompactionBudget)
        defer { await session.close() }
        let (log, drain) = await OutputLog.watch(session)

        let answerEvents = try await collect(await session.streamEvents(to: "compacts-first"))
        await session.close()
        await drain.value

        // The readers of the mail of the answer get the events of the
        // compaction that the answer started.
        #expect(answerEvents.answers.map(\.reply) == ["ok-compacts-first"])
        let start = try #require(answerEvents.compactionStarts.first)
        #expect(answerEvents.compactionStarts.map(\.reason) == [.triggerReached])
        #expect(answerEvents.compactionResults.map(\.id) == [start.id])
        #expect(answerEvents.answers.first?.compactions.map(\.id) == [start.id])

        // The id is a SignalID: the events have the origin of that signal,
        // and the ledger keeps the terminal event of the signal.
        let signal = SignalID(try #require(ULID(ulidString: start.id)))
        let end = try #require(await log.first { Self.endsCompaction($0, signal) })
        #expect(end.origin == .signal(signal))
        guard case .compaction = try #require(try Self.recordedTerminal(of: signal, on: session)) else {
            Issue.record("expected the ledger to keep the compaction of the signal")
            return
        }
    }

    /// The production change that makes this test fail: a requested
    /// compaction that offers only the own model.
    @Test("a requested compaction writes its summary with the flash tier")
    func aRequestedCompactionUsesTheFlashTier() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        defer { await session.close() }

        let terminal = try await session.awaitTerminal(of: Fixtures.requestSummarizingCompaction(of: session))

        guard case .compaction(let result) = terminal else {
            Issue.record("expected the compaction to complete, got \(terminal)")
            return
        }
        #expect(result.summarizerTier == .flash)
        #expect(await fixture.observer.entered.filter(Fixtures.isSummarizerCall).count == 1)
    }

    /// The production change that makes this test fail: a requested
    /// compaction with no own-model fallback.
    @Test("a requested compaction falls back to the own model when the flash tier fails")
    func aRequestedCompactionFallsBackToTheOwnModel() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        defer { await session.close() }
        let isFirst = Fixtures.firstSummarizerCall()
        fixture.hook.midAnswer = { prompt in
            guard isFirst(prompt) else { return }
            throw Fixtures.ProbeError.summarizerFailed
        }

        let terminal = try await session.awaitTerminal(of: Fixtures.requestSummarizingCompaction(of: session))

        guard case .compaction(let result) = terminal else {
            Issue.record("expected the compaction to complete, got \(terminal)")
            return
        }
        #expect(result.summarizerTier == .ownModel)
        #expect(await fixture.observer.entered.filter(Fixtures.isSummarizerCall).count == 2)
    }

    /// The production change that makes this test fail: a merge of two
    /// requests, or two compactions that run at the same time.
    @Test("two requested compactions run in order, each with its own events")
    func twoCompactionsRunInOrder() async throws {
        let dir = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let (log, drain) = await OutputLog.watch(session)
        let inside = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        Self.holdFirstSummarizerCall(fixture, inside: inside, release: release)
        defer {
            release.signal()
            await session.close()
        }

        let first = Fixtures.requestSummarizingCompaction(of: session)
        try await Self.waitForTheHold(inside, endingOn: { try await session.awaitTerminal(of: first) })
        let second = Fixtures.requestSummarizingCompaction(of: session)
        // The second compaction waits for the first: it did not start.
        #expect(await log.firstIndex { Self.startsCompaction($0, second) } == nil)

        release.signal()
        _ = try await session.awaitTerminal(of: first)
        _ = try await session.awaitTerminal(of: second)
        await session.close()
        await drain.value

        let firstStart = try #require(await log.firstIndex { Self.startsCompaction($0, first) })
        let firstEnd = try #require(await log.firstIndex { Self.endsCompaction($0, first) })
        let secondStart = try #require(await log.firstIndex { Self.startsCompaction($0, second) })
        let secondEnd = try #require(await log.firstIndex { Self.endsCompaction($0, second) })
        #expect(firstStart < firstEnd)
        #expect(firstEnd < secondStart)
        #expect(secondStart < secondEnd)
        TerminalEventLedger(events: await log.events).expectExactlyOneTerminal(forSignals: [first, second])
    }
}
