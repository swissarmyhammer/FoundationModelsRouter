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
/// it.
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

        let first = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = await session.send(Self.secondPrompt)
        let third = await session.send(Self.thirdPrompt)
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
        guard case .signal(let signal) = outputs[start].origin else {
            Issue.record("the compaction start has the origin \(outputs[start].origin), not a signal")
            return
        }
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

    @Test("the work of a caller compaction runs with the origin of a signal, and each answer with the mail of its message")
    func callerCompactionRunsWithASignal() async throws {
        let (session, standard, _) = try await AutoCompactionFixtures.makeTriggeredSession(
            budget: nil, tempDirPrefix: Self.tempDirPrefix)
        let answerCalls = standard.generationLog.calls
        #expect(answerCalls.count == AutoCompactionFixtures.answerCount)
        #expect(
            answerCalls.allSatisfy { call in
                guard case .mail(let mailIds) = call.origin else { return false }
                return mailIds.count == 1
            }, "\(answerCalls.map(\.origin))")
        #expect(Set(answerCalls.map(\.origin)).count == AutoCompactionFixtures.answerCount)

        try await session.compact(budget: AutoCompactionFixtures.fixedBudget)

        // A caller compaction sends no event of its own yet, so the test
        // reads the origin that its summarizer call ran with: the value each
        // event of the compaction reads.
        let summarizerCalls = standard.generationLog.calls.dropFirst(answerCalls.count)
        #expect(!summarizerCalls.isEmpty)
        let origins = Set(summarizerCalls.map(\.origin))
        #expect(origins.count == 1)
        guard case .signal = origins.first else {
            Issue.record("the summarizer call of a caller compaction ran with the origin \(origins)")
            return
        }
        await session.close()
    }

    // MARK: - Terminal events

    @Test(
        "a message that cancel(message:) withdraws while it waits gets exactly one cancelled event, no delivery and no answer"
    )
    func aWithdrawnMessageGetsOneCancelledEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let first = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let withdrawn = await session.send(Self.secondPrompt)
        #expect(await session.cancel(message: withdrawn) == .withdrawn)
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        let cancellations = outputs.filter { $0.event == .cancelled(withdrawn) }
        #expect(cancellations.map(\.origin) == [.mail([withdrawn])])
        #expect(!outputs.contains { $0.event == .mailDelivered(withdrawn) })
        #expect(Self.answered(in: outputs).map(\.mailIds) == [[first]])
        #expect(backend.prompts == [Self.firstPrompt])
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [first, withdrawn])
        withExtendedLifetime(profile) {}
    }

    @Test("cancel() gives one cancelled event to each message that waits, and the running answer ends once")
    func cancelGivesEachWaitingMessageACancelledEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let running = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = await session.send(Self.secondPrompt)
        let third = await session.send(Self.thirdPrompt)
        #expect(await session.cancel() == .requested)
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        #expect(Self.cancelledIds(in: outputs) == [second, third])
        for mailID in [second, third] {
            #expect(outputs.first { $0.event == .cancelled(mailID) }?.origin == .mail([mailID]))
        }
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [running, second, third])
        withExtendedLifetime(profile) {}
    }

    @Test("drain() gives one cancelled event to each message that waits, and the running answer ends once")
    func drainGivesEachWaitingMessageACancelledEvent() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await Self.makeSession(over: backend, dir: dir)
        let feed = await session.streamSessionEvents()

        let running = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = await session.send(Self.secondPrompt)
        let third = await session.send(Self.thirdPrompt)
        #expect(await session.drain())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        #expect(Self.cancelledIds(in: outputs) == [second, third])
        #expect(backend.prompts == [Self.firstPrompt])
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [running, second, third])
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

        let first = await session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let joined = await session.send(Self.secondPrompt)
        let withdrawn = await session.send(Self.thirdPrompt)
        #expect(await session.cancel(message: withdrawn) == .withdrawn)
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer, and the waiting message joins it.
        await latch.open()
        #expect(await session.becomesIdle())
        let later = await session.send(Self.laterPrompt)
        #expect(await session.becomesIdle())
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [first, joined, withdrawn, later])
        #expect(Self.answered(in: outputs).map(\.mailIds) == [[first, joined], [later]])
        #expect(Self.cancelledIds(in: outputs) == [withdrawn])

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
