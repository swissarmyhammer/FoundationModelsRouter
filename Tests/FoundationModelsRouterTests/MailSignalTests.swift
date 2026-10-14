import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the signals on the mail queue of a session (`mailbox.md`,
/// section 5): ``RoutedSession/cancel(_:)``, ``RoutedSession/cancelAll()``,
/// ``RoutedSession/replace(_:with:)``, ``RoutedSession/close()`` and the
/// refusal of ``RoutedSession/send(_:)-(Transcript.Prompt)``.
///
/// Each signal returns its ``SignalID`` at once, and its effect comes later.
/// A test waits for the terminal event of the signal
/// (``SessionEvent/signalDone(_:)``) before it checks the effect, and checks
/// the effect by the events or by the queue. ``RoutedSession/cancel(_:)``
/// and ``RoutedSession/replace(_:with:)`` act only on queued mail: they never
/// stop an answer that runs. ``RoutedSession/cancelAll()`` also stops the
/// running answer. Each mail and each signal gets exactly one terminal
/// event. The outbox keeps the ids of the held run mail
/// (``SessionOutbox/heldMailIDs``), and an id leaves that set when its mail
/// is delivered, cancelled or closed.
///
/// Everything runs on ``SessionMessagePumpTests/PumpProbeBackend`` through
/// ``MailQueueFixtures``. The suite needs no network and no GPU.
@Suite("The signals on the mail queue")
struct MailSignalTests {
    /// The backend the suite scripts.
    private typealias Backend = MailQueueFixtures.Backend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "MailSignalTests"

    /// The prompt of the message whose submission the test holds open.
    private static let heldPrompt = "held question"

    /// The prompt of the first queued message.
    private static let firstPrompt = "first queued question"

    /// The prompt of the second queued message.
    private static let secondPrompt = "second queued question"

    /// The prompt that a replace gives to a queued message.
    private static let replacedPrompt = "replaced question"

    /// A token ceiling that keeps a message out of the batch of a message
    /// with no ceiling.
    private static let namedCeiling = 100

    // MARK: - Fixtures

    /// Starts an answer for ``heldPrompt`` on a backend that `latch` holds
    /// open, and waits until its submission reached the backend.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - backend: The backend of the session.
    /// - Returns: The id of the held message.
    /// - Throws: When the submission does not reach the backend inside the
    ///   bound.
    private static func startHeldAnswer(on session: any RoutedSession, backend: Backend) async throws -> MailID {
        let held = try session.send(heldPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        return held
    }

    /// Posts one progress event to `session` and puts its run mail on hold.
    ///
    /// - Parameter session: The session.
    /// - Returns: The id of the held run mail.
    /// - Throws: When the post makes no queued mail.
    private static func postHeldRunMail(to session: any RoutedSession) async throws -> MailID {
        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a held step"), to: session)
        #expect(MailQueueFixtures.holdRunMail(of: session) == [runMail])
        #expect(session.outbox.heldMailIDs == [runMail])
        #expect(session.outbox.pendingRunMail.map(\.isHeld) == [true])
        return runMail
    }

    /// Reads `feed` to its end. Call it after ``RoutedSession/close()``,
    /// which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each event the feed delivered, in order.
    private static func events(of feed: AsyncStream<SessionOutput>) async -> [SessionEvent] {
        await collect(feed.events)
    }

    /// Reads `feed` to its end, with the origin of each event. Call it after
    /// ``RoutedSession/close()``, which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each output the feed delivered, in order.
    private static func outputs(of feed: AsyncStream<SessionOutput>) async -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        return outputs
    }

    /// The origin of each ``SessionEvent/cancelled(_:)`` of `outputs`, in
    /// order.
    ///
    /// - Parameter outputs: The output of a session.
    /// - Returns: The origins of the cancelled events.
    private static func cancelledOrigins(in outputs: [SessionOutput]) -> [Origin] {
        outputs.compactMap { output in
            guard case .cancelled = output.event else { return nil }
            return output.origin
        }
    }

    /// The prompt text of a queued user message.
    ///
    /// - Parameter mail: One queued mail.
    /// - Returns: The prompt, or `nil` for other mail.
    private static func prompt(of mail: Mail) -> String? {
        guard case .userMessage(let prompt, _) = mail.body else { return nil }
        return prompt
    }

    // MARK: - The held set

    @Test("held run mail leaves the held set when a user message delivers it")
    func deliveredHeldMailLeavesTheHeldSet() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let runMail = try await Self.postHeldRunMail(to: session)
        let message = try session.send(Self.firstPrompt)
        let terminal = try await session.awaitTerminal(of: message)

        #expect(session.outbox.heldMailIDs.isEmpty)
        #expect(session.outbox.queue.pending.isEmpty)
        let answer = try #require(MailQueueFixtures.answer(of: terminal), "the message ended with \(terminal)")
        #expect(Set(answer.mailIds) == [runMail, message])
        await session.close()
        TerminalEventLedger(events: await Self.events(of: feed)).expectExactlyOneTerminal(for: [runMail, message])
        withExtendedLifetime(profile) {}
    }

    @Test("held run mail leaves the held set when cancel(_:) removes it")
    func cancelledHeldMailLeavesTheHeldSet() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let runMail = try await Self.postHeldRunMail(to: session)
        let signal = session.cancel(runMail)
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))

        #expect(session.outbox.heldMailIDs.isEmpty)
        #expect(try await session.awaitTerminal(of: runMail) == .cancelled(runMail))
        await session.close()
        let events = await Self.events(of: feed)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail])
        #expect(backend.prompts.isEmpty)
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [runMail])
        ledger.expectExactlyOneTerminal(forSignals: [signal])
        withExtendedLifetime(profile) {}
    }

    @Test("held run mail leaves the held set when cancelAll() cancels it")
    func cancelAllEmptiesTheHeldSet() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let runMail = try await Self.postHeldRunMail(to: session)
        let signal = session.cancelAll()
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))

        #expect(session.outbox.heldMailIDs.isEmpty)
        #expect(session.outbox.queue.pending.isEmpty)
        #expect(try await session.awaitTerminal(of: runMail) == .cancelled(runMail))
        await session.close()
        let events = await Self.events(of: feed)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail])
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [runMail])
        ledger.expectExactlyOneTerminal(forSignals: [signal])
        withExtendedLifetime(profile) {}
    }

    // MARK: - A wait for run mail

    /// The production change that makes this test fail: a stage of run mail
    /// that does not make the id of the mail pending in the output of the
    /// session (``SessionOutbox/bind(outputHub:)``). The wait then throws
    /// ``TerminalLookupError/unknownMail(_:)`` for mail that waits in the
    /// queue.
    @Test("a cancelled wait for queued run mail ends with CancellationError, because the session knows the id of its run mail")
    func aWaitForQueuedRunMailKnowsItsID() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)

        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a queued step"), to: session)
        // A progress event starts no submission, so the run mail waits in
        // the queue until the cancel of the wait cancels it. The cancel
        // comes before or after the start of the wait; both orders end the
        // wait with CancellationError.
        let wait = Task { try await session.awaitAnswer(of: runMail) }
        wait.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await wait.value
        }
        #expect(try await session.awaitTerminal(of: runMail) == .cancelled(runMail))
        #expect(backend.prompts.isEmpty)
        await session.close()
        withExtendedLifetime(profile) {}
    }

    // MARK: - cancel(_:) and cancelAll()

    @Test("cancel(_:) of a queued mail sends one cancelled with the origin of the signal; a cancel of a delivered mail sends nothing and the answer goes on")
    func cancelActsOnlyOnQueuedMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let queued = try session.send(Self.firstPrompt)
        let cancelOfQueued = session.cancel(queued)
        // The first signal removes the mail, so this second cancel finds nothing.
        let secondCancel = session.cancel(queued)
        // The delivered mail is not in the queue, so its answer goes on.
        let cancelOfHeld = session.cancel(held)
        // The signals run in order, so the last one ends after the others.
        #expect(try await session.awaitTerminal(of: cancelOfHeld) == .signalDone(cancelOfHeld))
        #expect(try await session.awaitTerminal(of: queued) == .cancelled(queued))
        await latch.open()
        let terminal = try await session.awaitTerminal(of: held)
        await session.close()

        #expect(MailQueueFixtures.answer(of: terminal)?.mailIds == [held])
        let outputs = await Self.outputs(of: feed)
        let events = outputs.map(\.event)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [queued])
        #expect(Self.cancelledOrigins(in: outputs) == [.signal(cancelOfQueued)])
        #expect(events.answers.map(\.mailIds) == [[held]])
        #expect(backend.prompts == [Self.heldPrompt])
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [held, queued])
        ledger.expectExactlyOneTerminal(forSignals: [cancelOfQueued, secondCancel, cancelOfHeld])
        withExtendedLifetime(profile) {}
    }

    @Test("cancelAll() cancels each queued mail in queue order, also run mail, stops the running answer, and a second cancelAll() finds nothing")
    func cancelAllCancelsEachQueuedMailInOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a queued step"), to: session)
        let first = try session.send(Self.firstPrompt)
        let second = try session.send(Self.secondPrompt)

        let stop = session.cancelAll()
        let secondStop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: secondStop) == .signalDone(secondStop))
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.outputs(of: feed)
        let events = outputs.map(\.event)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail, first, second])
        // Only the first signal finds queued mail.
        #expect(Self.cancelledOrigins(in: outputs) == Array(repeating: .signal(stop), count: 3))
        #expect(events.answers.isEmpty)
        #expect(events.answerFailures == [AnswerFailure(mailIds: [held], reason: .cancelled)])
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [held, runMail, first, second])
        ledger.expectExactlyOneTerminal(forSignals: [stop, secondStop])
        withExtendedLifetime(profile) {}
    }

    // MARK: - replace(_:with:)

    @Test("replace(_:with:) of a queued mail changes the prompt the model gets, with the same id and place; mail that is not queued is not changed")
    func replaceChangesAQueuedMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let replaced = try session.send(Self.firstPrompt)
        let behind = RoutedSessionActor.userMessage(Self.secondPrompt, maxTokens: Self.namedCeiling, mode: .reply)
        _ = try session.mail(behind)
        let newBody = MailBody.userMessage(prompt: Self.replacedPrompt, options: UserMessageOptions())

        let applied = session.replace(replaced, with: newBody)
        #expect(try await session.awaitTerminal(of: applied) == .signalDone(applied))
        let pending = await session.pendingMessages()
        #expect(pending.map(\.id) == [replaced, behind.id])
        #expect(pending.map(Self.prompt(of:)) == [Self.replacedPrompt, Self.secondPrompt])
        // The delivered mail and an unknown id are not in the queue, so the
        // queue does not change.
        let replaceOfHeld = session.replace(held, with: newBody)
        let replaceOfUnknown = session.replace(MailID(), with: newBody)
        #expect(try await session.awaitTerminal(of: replaceOfUnknown) == .signalDone(replaceOfUnknown))
        let unchanged = await session.pendingMessages()
        #expect(unchanged.map(\.id) == [replaced, behind.id])
        #expect(unchanged.map(Self.prompt(of:)) == [Self.replacedPrompt, Self.secondPrompt])
        await latch.open()
        #expect(await session.becomesIdle())
        // The mail was delivered, so it is not in the queue any more, and the
        // model gets no new prompt.
        let lateReplace = session.replace(replaced, with: newBody)
        #expect(try await session.awaitTerminal(of: lateReplace) == .signalDone(lateReplace))
        #expect(await session.pendingMessages().isEmpty)
        await session.close()

        #expect(backend.prompts == [Self.heldPrompt, Self.replacedPrompt, Self.secondPrompt])
        let events = await Self.events(of: feed)
        #expect(events.answers.map(\.mailIds) == [[held], [replaced], [behind.id]])
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [held, replaced, behind.id])
        ledger.expectExactlyOneTerminal(forSignals: [applied, replaceOfHeld, replaceOfUnknown, lateReplace])
        withExtendedLifetime(profile) {}
    }

    // MARK: - cancelAll() of the running answer, and close()

    @Test("cancelAll() stops the running answer and gives cancelled to each queued mail, also run mail, before its signalDone")
    func cancelAllStopsTheRunningAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a queued step"), to: session)
        let queued = try session.send(Self.firstPrompt)
        let stop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stop) == .signalDone(stop))

        #expect(session.outbox.queue.pending.isEmpty)
        #expect(session.outbox.heldMailIDs.isEmpty)
        // The stopped answer ends at once, also while the backend still
        // holds its model call.
        let heldEnd = try await session.awaitTerminal(of: held)
        #expect(heldEnd == .answerFailed(AnswerFailure(mailIds: [held], reason: .cancelled)))
        await session.close()
        let events = await Self.events(of: feed)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail, queued])
        #expect(events.answerFailures == [AnswerFailure(mailIds: [held], reason: .cancelled)])
        let done = try #require(events.firstIndex(of: .signalDone(stop)))
        let lastTerminal = try #require(
            events.lastIndex { TerminalEventLedger.mailIdsEnded(by: $0) != nil })
        #expect(lastTerminal < done)
        #expect(backend.prompts == [Self.heldPrompt])
        let ledger = TerminalEventLedger(events: events)
        ledger.expectExactlyOneTerminal(for: [held, runMail, queued])
        ledger.expectExactlyOneTerminal(forSignals: [stop])
        withExtendedLifetime(profile) {}
    }

    @Test("close() gives cancelled to each queued mail, also run mail, and ends the running answer")
    func closeCancelsEachQueuedMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let held = try await Self.startHeldAnswer(on: session, backend: backend)
        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a queued step"), to: session)
        let queued = try session.send(Self.firstPrompt)
        await session.close()

        #expect(session.outbox.queue.pending.isEmpty)
        // The close finishes the feed before its drain, so the feed has the
        // cancelled events of the queued mail. The ledger of the session
        // keeps the end of the running answer.
        let events = await Self.events(of: feed)
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail, queued])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [runMail, queued])
        let heldEnd = try await session.awaitTerminal(of: held)
        #expect(heldEnd == .answerFailed(AnswerFailure(mailIds: [held], reason: .cancelled)))
        #expect(backend.prompts == [Self.heldPrompt])
        withExtendedLifetime(profile) {}
    }

    // MARK: - The refusal of send

    @Test("send(_:) of a prompt with no text segment throws noTextSegment and queues nothing")
    func sendRefusesAPromptWithNoText() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)

        #expect(throws: PromptRefusal.noTextSegment) {
            try session.send(Transcript.Prompt(segments: []))
        }
        #expect(session.outbox.queue.pending.isEmpty)
        #expect(await session.isPumpRunning == false)
        await session.close()
        #expect(backend.prompts.isEmpty)
        withExtendedLifetime(profile) {}
    }
}
