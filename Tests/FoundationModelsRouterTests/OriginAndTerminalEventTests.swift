import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the origin of each output event and the terminal events of each
/// caller message (`mailbox.md`, sections 4 and 5).
///
/// Each element of ``RoutedSession/streamSessionEvents()`` is a
/// ``SessionOutput``: the event and the ``Origin`` of the work that sent it.
/// The events of an answer have the origin ``Origin/mail(_:)`` with the ids
/// of the messages of the answer, and the events of a compaction have the
/// origin ``Origin/signal(_:)``. The pump sends
/// ``SessionEvent/mailDelivered(_:)`` for each message that an answer
/// delivers, before the submission that carries it. Each message gets
/// exactly one terminal event: the end of the answer that carries it, or
/// ``SessionEvent/cancelled(_:)`` when it left the queue before the pump took
/// it. A signal (``RoutedSession/cancel(_:)``, ``RoutedSession/cancelAll()``)
/// gives the mail that it removes the origin ``Origin/signal(_:)`` of its
/// ``SignalID``, and ends with exactly one ``SessionEvent/signalDone(_:)``
/// after its other events.
///
/// Everything runs against ``SessionMessagePumpTests/PumpProbeBackend``, a
/// stub backend that can hold a call open, and the stub containers of
/// ``AutoCompactionFixtures``. The suite needs no network and no GPU.
@Suite("The origin of each output event, and one terminal event for each message")
struct OriginAndTerminalEventTests {
    /// The backend the suite scripts.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "OriginAndTerminalEventTests"

    /// The prompt of the message that starts the first answer.
    private static let firstPrompt = "first question"

    /// The prompt of the second message.
    private static let secondPrompt = "second question"

    /// The prompt of the third message.
    private static let thirdPrompt = "third question"

    /// The prompt of the message that the test sends after the first answers.
    private static let laterPrompt = "later question"

    /// How many answers the batch test drives.
    private static let twoAnswers = 2

    /// Makes a session over `backend`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The temporary directory the router caches under.
    /// - Returns: The session and the profile that keeps its models resident.
    private static func makeSession(
        over backend: Backend, dir: URL
    ) async throws -> (session: any RoutedSession, profile: LanguageModelProfile) {
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: dir
        ).profile
        return (profile.standard.makeSession(), profile)
    }

    /// Reads `feed` to its end. Call it after ``RoutedSession/close()``,
    /// which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each output the feed delivered, in order.
    private static func collectOutputs(_ feed: AsyncStream<SessionOutput>) async -> [SessionOutput] {
        var outputs: [SessionOutput] = []
        for await output in feed {
            outputs.append(output)
        }
        return outputs
    }

    /// Splits `outputs` after each end of an answer.
    ///
    /// - Parameter outputs: The output of a session, in order.
    /// - Returns: The output of each answer, in order. Output after the last
    ///   end of an answer is not in the result.
    private static func answers(in outputs: [SessionOutput]) -> [[SessionOutput]] {
        var answers: [[SessionOutput]] = []
        var current: [SessionOutput] = []
        for output in outputs {
            current.append(output)
            if output.event.isAnswerEnd {
                answers.append(current)
                current = []
            }
        }
        return answers
    }

    /// The answers in `outputs`, in order.
    ///
    /// - Parameter outputs: The output of a session, in order.
    /// - Returns: The ``SessionEvent/answered(_:)`` payloads.
    private static func answered(in outputs: [SessionOutput]) -> [SessionAnswer] {
        outputs.map(\.event).answers
    }

    /// The ids of the ``SessionEvent/cancelled(_:)`` events in `outputs`, in
    /// order.
    ///
    /// - Parameter outputs: The output of a session, in order.
    /// - Returns: The cancelled ids.
    private static func cancelledIds(in outputs: [SessionOutput]) -> [MailID] {
        outputs.compactMap { output in
            guard case .cancelled(let mailID) = output.event else { return nil }
            return mailID
        }
    }

    /// Whether `event` is an event of a compaction.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for a compaction start, a compaction, or a failed
    ///   compaction.
    private static func isCompactionEvent(_ event: SessionEvent) -> Bool {
        switch event {
        case .compactionStarted, .compaction, .compactionFailed: true
        default: false
        }
    }

    /// The signal of `origin`.
    ///
    /// - Parameter origin: The origin of one output event.
    /// - Returns: The id of the signal, or `nil` when `origin` is not
    ///   ``Origin/signal(_:)``.
    private static func signal(of origin: Origin) -> SignalID? {
        switch origin {
        case .signal(let signal): signal
        case .mail, .system: nil
        }
    }

    /// Whether `event` is the terminal event ``SessionEvent/answered(_:)``.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for an answered event.
    private static func isAnswered(_ event: SessionEvent) -> Bool {
        if case .answered = event {
            return true
        }
        return false
    }

    /// Whether `event` is the terminal event of the mail `mailID`: an answer
    /// or an answer failure that names it, or its
    /// ``SessionEvent/cancelled(_:)`` or ``SessionEvent/lost(_:)``.
    ///
    /// - Parameters:
    ///   - event: One event of a session.
    ///   - mailID: The id of one mail.
    /// - Returns: `true` when the event ends the mail.
    private static func isTerminal(_ event: SessionEvent, of mailID: MailID) -> Bool {
        switch event {
        case .answered(let answer): answer.mailIds.contains(mailID)
        case .answerFailed(let failure): failure.mailIds.contains(mailID)
        case .cancelled(let id), .lost(let id): id == mailID
        default: false
        }
    }

    /// Waits for the end of the signal `signal`, and expects that its
    /// terminal event is ``SessionEvent/signalDone(_:)``. The effect of a
    /// signal is not synchronous, so a test calls this before it checks the
    /// effect.
    ///
    /// - Parameters:
    ///   - signal: The id of the signal.
    ///   - session: The session that got the signal.
    /// - Throws: When the wait for the terminal event fails.
    private static func awaitSignalEnd(_ signal: SignalID, on session: any RoutedSession) async throws {
        #expect(try await session.awaitTerminal(of: signal) == .signalDone(signal))
    }

    /// Checks the end of the signal `signal` in `outputs`: exactly one
    /// ``SessionEvent/signalDone(_:)`` with the origin of the signal, and it
    /// comes after the terminal event of each mail of `mailIds`, which the
    /// signal ended.
    ///
    /// - Parameters:
    ///   - signal: The id of the signal.
    ///   - mailIds: The ids of the mail that the signal ended.
    ///   - outputs: The output of a session, in order.
    ///   - sourceLocation: The place of the call, for the issue.
    /// - Throws: When the output has no ``SessionEvent/signalDone(_:)`` of
    ///   the signal.
    private static func expectSignalEnd(
        of signal: SignalID, after mailIds: [MailID], in outputs: [SessionOutput],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let ends = outputs.indices.filter { outputs[$0].event == .signalDone(signal) }
        #expect(ends.count == 1, "signal \(signal) has \(ends.count) signalDone events", sourceLocation: sourceLocation)
        let end = try #require(ends.first, sourceLocation: sourceLocation)
        #expect(outputs[end].origin == .signal(signal), sourceLocation: sourceLocation)
        for mailID in mailIds {
            let terminal = outputs.firstIndex { Self.isTerminal($0.event, of: mailID) }
            #expect(
                terminal.map { $0 < end } == true,
                "the terminal event of \(mailID) does not come before the signalDone of \(signal)",
                sourceLocation: sourceLocation)
        }
    }

    /// Checks the output of one answer that delivered `mailIds` in one
    /// submission: each event has the origin of the batch, and the answer
    /// opens with one ``SessionEvent/mailDelivered(_:)`` for each message, in
    /// delivery order, before its submission starts.
    ///
    /// - Parameters:
    ///   - answer: The output of the answer, from its first event to its end.
    ///   - mailIds: The ids of the messages of the batch, in delivery order.
    private static func expectAnswer(_ answer: [SessionOutput], delivering mailIds: [MailID]) {
        let origin = Origin.mail(Set(mailIds))
        #expect(answer.allSatisfy { $0.origin == origin }, "an event of the answer has another origin: \(answer)")
        #expect(
            answer.prefix(mailIds.count).map(\.event) == mailIds.map(SessionEvent.mailDelivered),
            "the answer does not open with the delivery of its messages: \(answer.map(\.event))")
        let deliveries = answer.filter {
            if case .mailDelivered = $0.event { return true }
            return false
        }
        #expect(deliveries.count == mailIds.count)
        #expect(answer.contains { if case .submissionStarted = $0.event { return true } else { return false } })
    }

    // MARK: - Origin

    @Test(
        "the events of an answer carry the mail of its batch, and the delivery of each message comes before its submission"
    )
    func answerEventsCarryTheMailOfTheirBatch() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let first = try session.send(Self.firstPrompt)
        try await backend.waitForPrompts(1)
        let second = try session.send(Self.secondPrompt)
        let third = try session.send(Self.thirdPrompt)
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        let answers = Self.answers(in: outputs)
        #expect(answers.count == Self.twoAnswers)
        if answers.count == Self.twoAnswers {
            Self.expectAnswer(answers[0], delivering: [first])
            Self.expectAnswer(answers[1], delivering: [second, third])
        }
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [first, second, third])
        withExtendedLifetime(profile) {}
    }

    @Test(
        "the events of an automatic compaction inside an answer carry one signal, and the other events of the answer carry its mail"
    )
    func automaticCompactionEventsCarryASignal() async throws {
        let (session, _, flash) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: AutoCompactionFixtures.fixedBudget, tempDirPrefix: Self.tempDirPrefix)
        let feed = await session.streamSessionEvents()

        _ = try await session.respond(to: Self.laterPrompt)
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        let start = try #require(outputs.firstIndex { Self.isCompactionEvent($0.event) })
        let end = try #require(outputs.lastIndex { Self.isCompactionEvent($0.event) })
        let signal = try #require(
            Self.signal(of: outputs[start].origin),
            "the compaction start has the origin \(outputs[start].origin), not a signal")
        let compaction = outputs[start...end]
        #expect(compaction.allSatisfy { $0.origin == .signal(signal) }, "\(Array(compaction))")

        let answer = try #require(Self.answered(in: outputs).first)
        #expect(answer.mailIds.count == 1)
        let rest = outputs[..<start] + outputs[(end + 1)...]
        #expect(rest.allSatisfy { $0.origin == .mail(Set(answer.mailIds)) }, "\(Array(rest))")
        #expect(rest.first?.event == answer.mailIds.first.map(SessionEvent.mailDelivered))

        // The summarizer of the compaction is a model call of the flash slot.
        // The call keeps the signal of its compaction.
        let summarizerCalls = flash.generationLog.calls
        #expect(!summarizerCalls.isEmpty)
        #expect(summarizerCalls.allSatisfy { $0.origin == .signal(signal) })
    }

    /// The production change that makes this test fail: a requested
    /// compaction that sends no event, sends an event with an origin other
    /// than the signal that ``RoutedSession/compact(prompt:budget:)``
    /// returned, or runs its summarizer call with an other origin.
    @Test(
        "each event of a requested compaction and its summarizer call have the origin of the returned signal, and each answer the mail of its message"
    )
    func requestedCompactionEventsHaveTheReturnedSignal() async throws {
        let (session, standard, flash) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)
        let feed = await session.streamSessionEvents()
        let answerCalls = standard.generationLog.calls
        #expect(answerCalls.count == AutoCompactionFixtures.answerCount)
        #expect(
            answerCalls.allSatisfy { call in
                guard case .mail(let mailIds) = call.origin else { return false }
                return mailIds.count == 1
            }, "\(answerCalls.map(\.origin))")
        #expect(Set(answerCalls.map(\.origin)).count == AutoCompactionFixtures.answerCount)

        let id = session.compact(budget: AutoCompactionFixtures.fixedBudget)
        let terminal = try await session.awaitTerminal(of: id)
        _ = try compactionResult(of: terminal)
        await session.close()

        // A requested compaction sends its start and its terminal event on
        // the feed of the session, each with the origin of its signal.
        let outputs = await Self.collectOutputs(feed)
        let compaction = outputs.filter { Self.isCompactionEvent($0.event) }
        #expect(compaction.count == 2, "\(compaction)")
        #expect(compaction.allSatisfy { $0.origin == .signal(id) }, "\(compaction)")
        guard case .compactionStarted(let start)? = compaction.first?.event else {
            Issue.record("the first compaction event is not compactionStarted: \(compaction)")
            return
        }
        #expect(start.id == id.description)
        #expect(start.reason == .requested)
        #expect(compaction.last?.event == terminal)

        // A requested compaction offers the flash slot first. Its summarizer
        // call keeps the signal of its compaction, and the session's own
        // model makes no call for it.
        let summarizerCalls = flash.generationLog.calls
        #expect(!summarizerCalls.isEmpty)
        #expect(
            summarizerCalls.allSatisfy { $0.origin == .signal(id) },
            "the summarizer call of a requested compaction ran with the origins \(summarizerCalls.map(\.origin))")
        #expect(standard.generationLog.calls.count == answerCalls.count)
    }

    // MARK: - Terminal events

    @Test(
        "a message that cancel(_:) removes while it waits gets exactly one cancelled event, no delivery and no answer"
    )
    func aWithdrawnMessageGetsOneCancelledEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let first = try session.send(Self.firstPrompt)
        try await backend.waitForPrompts(1)
        let withdrawn = try session.send(Self.secondPrompt)
        let removal = session.cancel(withdrawn)
        try await Self.awaitSignalEnd(removal, on: session)
        #expect(try await session.awaitTerminal(of: withdrawn) == .cancelled(withdrawn))
        // The mail is not in the queue now, so a second cancel does nothing
        // and sends no second terminal event.
        let repeated = session.cancel(withdrawn)
        try await Self.awaitSignalEnd(repeated, on: session)
        // The running answer is not queued mail, so a cancel of its id does
        // not stop it.
        let ofRunning = session.cancel(first)
        try await Self.awaitSignalEnd(ofRunning, on: session)
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        let cancellations = outputs.filter { $0.event == .cancelled(withdrawn) }
        #expect(cancellations.map(\.origin) == [.signal(removal)])
        try Self.expectSignalEnd(of: removal, after: [withdrawn], in: outputs)
        try Self.expectSignalEnd(of: repeated, after: [], in: outputs)
        try Self.expectSignalEnd(of: ofRunning, after: [], in: outputs)
        #expect(!outputs.contains { $0.event == .mailDelivered(withdrawn) })
        #expect(Self.answered(in: outputs).map(\.mailIds) == [[first]])
        #expect(backend.prompts == [Self.firstPrompt])
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [first, withdrawn])
        withExtendedLifetime(profile) {}
    }

    @Test(
        "cancelAll() gives one cancelled event with the origin of its signal to each message that waits, ends the running answer with one answerFailed, and ends with one signalDone"
    )
    func cancelAllGivesEachWaitingMessageACancelledEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let running = try session.send(Self.firstPrompt)
        try await backend.waitForPrompts(1)
        let second = try session.send(Self.secondPrompt)
        let third = try session.send(Self.thirdPrompt)
        let stop = session.cancelAll()
        try await Self.awaitSignalEnd(stop, on: session)
        // The queue is empty now, and the stopped answer has its terminal
        // event, so a second signal cancels nothing and sends no second
        // terminal event, also while the stopped work still unwinds.
        let repeated = session.cancelAll()
        try await Self.awaitSignalEnd(repeated, on: session)
        // The signal does not wait for the pump. The latch never opens, so
        // the held call ends only with the cancel of the signal.
        #expect(await session.isIdleOnceThePumpEnds())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        #expect(Self.cancelledIds(in: outputs) == [second, third])
        for mailID in [second, third] {
            #expect(outputs.first { $0.event == .cancelled(mailID) }?.origin == .signal(stop))
        }
        try Self.expectSignalEnd(of: stop, after: [second, third, running], in: outputs)
        try Self.expectSignalEnd(of: repeated, after: [], in: outputs)
        let events = outputs.map(\.event)
        #expect(events.answers.isEmpty)
        #expect(events.answerFailures == [AnswerFailure(mailIds: [running], reason: .cancelled)])
        let failure = try #require(outputs.first { $0.event.isAnswerEnd })
        #expect(failure.origin == .mail([running]))
        #expect(backend.prompts == [Self.firstPrompt])
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [running, second, third])
        withExtendedLifetime(profile) {}
    }

    @Test(
        "after cancelAll() the session stays usable: a message sent after the signal ended gets its own answer when the stopped work ended"
    )
    func aMessageAfterCancelAllGetsItsAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let stopped = try session.send(Self.firstPrompt)
        try await backend.waitForPrompts(1)
        let stop = session.cancelAll()
        try await Self.awaitSignalEnd(stop, on: session)
        // The signal ended, so its cancel of the queued mail does not remove
        // this message. The message waits until the stopped work ended, and
        // then it gets its answer.
        let later = try session.send(Self.laterPrompt)
        #expect(Self.isAnswered(try await session.awaitTerminal(of: later)))
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        try Self.expectSignalEnd(of: stop, after: [stopped], in: outputs)
        #expect(Self.answered(in: outputs).map(\.mailIds) == [[later]])
        #expect(outputs.map(\.event).answerFailures == [AnswerFailure(mailIds: [stopped], reason: .cancelled)])
        #expect(backend.prompts == [Self.firstPrompt, Self.laterPrompt])
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [stopped, later])
        withExtendedLifetime(profile) {}
    }

    @Test(
        "each message gets exactly one terminal event in a mix of answered, joined and cancelled messages, and a joined message adds its id to the origin"
    )
    func eachMessageGetsExactlyOneTerminalEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .holdThenReject(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let first = try session.send(Self.firstPrompt)
        try await backend.waitForPrompts(1)
        let joined = try session.send(Self.secondPrompt)
        let withdrawn = try session.send(Self.thirdPrompt)
        let removal = session.cancel(withdrawn)
        try await Self.awaitSignalEnd(removal, on: session)
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer, and the waiting message joins it.
        await latch.open()
        #expect(await session.becomesIdle())
        let later = try session.send(Self.laterPrompt)
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [first, joined, withdrawn, later])
        #expect(Self.answered(in: outputs).map(\.mailIds) == [[first, joined], [later]])
        #expect(Self.cancelledIds(in: outputs) == [withdrawn])
        try Self.expectSignalEnd(of: removal, after: [withdrawn], in: outputs)

        let starts = outputs.filter { if case .submissionStarted = $0.event { return true } else { return false } }
        #expect(starts.map(\.origin) == [.mail([first]), .mail([first, joined]), .mail([later])])
        let joinedDelivery = try #require(outputs.firstIndex { $0.event == .mailDelivered(joined) })
        #expect(outputs[joinedDelivery].origin == .mail([first, joined]))
        let continuationStart = try #require(
            outputs.firstIndex { output in
                guard case .submissionStarted(let start) = output.event else { return false }
                return start.cause == .continuation
            })
        #expect(joinedDelivery < continuationStart)
        let firstAnswerEnd = try #require(outputs.firstIndex { $0.event.isAnswerEnd })
        #expect(outputs[firstAnswerEnd].origin == .mail([first, joined]))
        withExtendedLifetime(profile) {}
    }
}
