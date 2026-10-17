import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the batch rule of the mail queue of a session (`mailbox.md`,
/// sections 4 and 5).
///
/// The pump takes one batch for each answer. The first user-type mail is the
/// leader, and its options decide the batch: a stream goes alone, and the
/// token ceiling is part of the key. All run mail rides a batch that has a
/// user-type leader. Mail that arrives while an answer runs joins the next
/// continuation of that answer when the options of the answer admit it. Run
/// mail that cannot start a submission (for example progress) starts no
/// answer, and the pump does not loop on it.
///
/// The session tests run on ``SessionMessagePumpTests/PumpProbeBackend``
/// through ``MailQueueFixtures``. The rule tests call the rule functions
/// directly. The suite needs no network and no GPU.
@Suite("The batch rule of the mail queue")
struct MailQueueBatchTests {
    /// The backend the suite scripts.
    private typealias Backend = MailQueueFixtures.Backend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "MailQueueBatchTests"

    /// The prompt of the message whose submission the test holds open.
    private static let heldPrompt = "held question"

    /// The prompt of the first queued message.
    private static let firstPrompt = "first queued question"

    /// The prompt of the second queued message.
    private static let secondPrompt = "second queued question"

    /// The prompt of the third queued message.
    private static let thirdPrompt = "third queued question"

    /// One token ceiling that a caller names.
    private static let smallCeiling = 100

    /// A token ceiling that is not ``smallCeiling``.
    private static let largeCeiling = 200

    // MARK: - Fixtures

    /// A user message in reply mode.
    ///
    /// - Parameters:
    ///   - prompt: The prompt text.
    ///   - maxTokens: The token ceiling, or `nil`.
    /// - Returns: The mail, with a new id.
    private static func reply(_ prompt: String, maxTokens: Int? = nil) -> Mail {
        RoutedSessionActor.userMessage(prompt, maxTokens: maxTokens, mode: .reply)
    }

    /// A user message in stream mode.
    ///
    /// - Parameter prompt: The prompt text.
    /// - Returns: The mail, with a new id.
    private static func stream(_ prompt: String) -> Mail {
        RoutedSessionActor.userMessage(prompt, maxTokens: nil, mode: .stream)
    }

    /// One run mail of the probe run, with a progress event.
    ///
    /// - Parameter detail: The detail of the event.
    /// - Returns: The mail, with a new id.
    private static func runMail(_ detail: String) -> Mail {
        let event = MailQueueFixtures.progressEvent(detail: detail)
        return Mail(sender: .run(correlationID: event.correlationID), body: .runEvent(event))
    }

    /// Puts `mail` in a new queue, in order.
    ///
    /// - Parameter mail: The mail to put.
    /// - Returns: The queue.
    /// - Throws: The refusal of the queue.
    private static func queue(of mail: [Mail]) throws -> MailQueue {
        let queue = MailQueue()
        for item in mail {
            try queue.put(item)
        }
        return queue
    }

    /// Takes one batch from `queue` with the batch rule of a new answer, for
    /// a session with no grammar.
    ///
    /// - Parameter queue: The queue.
    /// - Returns: The ids of the batch, in queue order.
    private static func takeBatch(from queue: MailQueue) -> [MailID] {
        queue.take { RoutedSessionActor.joinsNewBatch($0, $1, isGuided: false) }.map(\.id)
    }

    /// Reads `feed` to its end. Call it after ``RoutedSession/close()``,
    /// which finishes the feed.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each event the feed delivered, in order.
    private static func events(of feed: AsyncStream<SessionOutput>) async -> [SessionEvent] {
        await collect(feed.events)
    }

    // MARK: - The rule functions

    @Test("a batch takes the leader, each later reply with the same ceiling, and all run mail; a stream and another ceiling wait")
    func newBatchRuleTakesTheMailTheLeaderAdmits() throws {
        let progress = Self.runMail("step one")
        let leader = Self.reply(Self.firstPrompt, maxTokens: Self.smallCeiling)
        let streamed = Self.stream(Self.secondPrompt)
        let otherCeiling = Self.reply(Self.thirdPrompt, maxTokens: Self.largeCeiling)
        let sameCeiling = Self.reply(Self.heldPrompt, maxTokens: Self.smallCeiling)
        let laterProgress = Self.runMail("step two")
        let queue = try Self.queue(of: [progress, leader, streamed, otherCeiling, sameCeiling, laterProgress])

        #expect(Self.takeBatch(from: queue) == [progress.id, leader.id, sameCeiling.id, laterProgress.id])
        // The stream is the next leader, and it goes alone.
        #expect(Self.takeBatch(from: queue) == [streamed.id])
        #expect(Self.takeBatch(from: queue) == [otherCeiling.id])
        #expect(queue.pending.isEmpty)
    }

    @Test("a stream leader admits no reply, and a reply leader admits no stream")
    func aStreamGoesAlone() {
        let streamed = Self.stream(Self.firstPrompt)
        let reply = Self.reply(Self.secondPrompt)

        #expect(!RoutedSessionActor.joinsNewBatch(reply, [streamed], isGuided: false))
        #expect(!RoutedSessionActor.joinsNewBatch(streamed, [reply], isGuided: false))
        #expect(!RoutedSessionActor.joinsNewBatch(Self.stream(Self.thirdPrompt), [streamed], isGuided: false))
        // Run mail rides each batch, also a stream.
        #expect(RoutedSessionActor.joinsNewBatch(Self.runMail("step"), [streamed], isGuided: false))
    }

    @Test("the token ceiling is part of the key: two replies join only when their ceilings are the same")
    func theCeilingIsPartOfTheKey() {
        let small = Self.reply(Self.firstPrompt, maxTokens: Self.smallCeiling)

        #expect(RoutedSessionActor.joinsNewBatch(Self.reply(Self.secondPrompt, maxTokens: Self.smallCeiling), [small], isGuided: false))
        #expect(!RoutedSessionActor.joinsNewBatch(Self.reply(Self.secondPrompt, maxTokens: Self.largeCeiling), [small], isGuided: false))
        #expect(!RoutedSessionActor.joinsNewBatch(Self.reply(Self.secondPrompt), [small], isGuided: false))
    }

    @Test("the first user-type mail is the leader: user-type mail joins a batch that holds only run mail")
    func theFirstUserMailIsTheLeader() {
        let progress = Self.runMail("step")

        #expect(RoutedSessionActor.joinsNewBatch(progress, [], isGuided: false))
        #expect(RoutedSessionActor.joinsNewBatch(Self.stream(Self.firstPrompt), [progress], isGuided: false))
        #expect(RoutedSessionActor.joinsNewBatch(Self.reply(Self.firstPrompt), [progress], isGuided: false))
    }

    @Test("an agent message and an elicitation answer are replies with no ceiling, so they join a reply with no ceiling")
    func agentAndElicitationMailAreReplies() {
        let agent = Mail(sender: .session(ULID()), body: .agentMessage(from: ULID(), content: "hello"))
        let answer = Mail(
            sender: .elicitation(ULID()), body: .elicitationAnswer(id: ULID(), response: .decline))
        let reply = Self.reply(Self.firstPrompt)

        #expect(SubmissionOptions(for: agent, isGuided: false) == .mailDelivery)
        #expect(SubmissionOptions(for: answer, isGuided: false) == .mailDelivery)
        #expect(RoutedSessionActor.joinsNewBatch(agent, [reply], isGuided: false))
        #expect(RoutedSessionActor.joinsNewBatch(answer, [reply, agent], isGuided: false))
        #expect(!RoutedSessionActor.joinsNewBatch(agent, [Self.reply(Self.firstPrompt, maxTokens: Self.smallCeiling)], isGuided: false))
    }

    @Test("a guided session never streams, so a stream message joins a reply leader")
    func aGuidedStreamIsAReply() {
        let streamed = Self.stream(Self.firstPrompt)

        #expect(SubmissionOptions(for: streamed, isGuided: true) == SubmissionOptions(isStream: false, requestedMaxTokens: nil))
        #expect(RoutedSessionActor.joinsNewBatch(streamed, [Self.reply(Self.secondPrompt)], isGuided: true))
        #expect(RoutedSessionActor.joinsNewBatch(Self.reply(Self.secondPrompt), [streamed], isGuided: true))
    }

    @Test("run mail has no options of its own and always joins a running answer")
    func runMailAlwaysJoinsARunningAnswer() {
        let progress = Self.runMail("step")
        let streamOptions = SubmissionOptions(isStream: true, requestedMaxTokens: nil)

        #expect(SubmissionOptions(for: progress, isGuided: false) == nil)
        #expect(RoutedSessionActor.joinsRunningAnswer(progress, options: streamOptions, isGuided: false))
        #expect(RoutedSessionActor.joinsRunningAnswer(progress, options: .mailDelivery, isGuided: false))
    }

    @Test("user-type mail joins a running answer only when the options of the answer admit it")
    func userMailJoinsARunningAnswerWhenAdmitted() {
        let streamOptions = SubmissionOptions(isStream: true, requestedMaxTokens: nil)
        let smallOptions = SubmissionOptions(isStream: false, requestedMaxTokens: Self.smallCeiling)

        #expect(RoutedSessionActor.joinsRunningAnswer(Self.reply(Self.firstPrompt), options: .mailDelivery, isGuided: false))
        #expect(!RoutedSessionActor.joinsRunningAnswer(Self.reply(Self.firstPrompt), options: streamOptions, isGuided: false))
        #expect(!RoutedSessionActor.joinsRunningAnswer(Self.stream(Self.firstPrompt), options: .mailDelivery, isGuided: false))
        #expect(
            RoutedSessionActor.joinsRunningAnswer(
                Self.reply(Self.firstPrompt, maxTokens: Self.smallCeiling), options: smallOptions, isGuided: false))
        #expect(
            !RoutedSessionActor.joinsRunningAnswer(
                Self.reply(Self.firstPrompt, maxTokens: Self.largeCeiling), options: smallOptions, isGuided: false))
    }

    // MARK: - The batch rule on a session

    @Test("a user message carries the queued run mail: one submission has the run mail preamble and the prompt, and the answer has both ids")
    func aUserLeaderCarriesTheQueuedRunMail() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer { await session.close() }
        let feed = await session.streamSessionEvents()

        let event = MailQueueFixtures.progressEvent(detail: "half of the work is done")
        let runMail = try await MailQueueFixtures.post(event, to: session)
        let message = try session.send(Self.firstPrompt)
        let terminal = try await session.awaitTerminal(of: message)
        await session.close()

        let prompt = try #require(backend.prompts.first)
        #expect(backend.prompts.count == 1)
        #expect(prompt.contains(OperationEventSegment.renderedLine(for: event)))
        #expect(prompt.hasSuffix(Self.firstPrompt))
        let answer = try #require(MailQueueFixtures.answer(of: terminal), "the message ended with \(terminal)")
        #expect(Set(answer.mailIds) == [runMail, message])
        #expect(answer.mailIds.count == 2)
        let events = await Self.events(of: feed)
        #expect(events.answers.map(\.mailIds) == [answer.mailIds])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [runMail, message])
        withExtendedLifetime(profile) {}
    }

    @Test("a stream message goes alone: a reply queued behind it is a second answer")
    func aStreamMessageGoesAlone() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer {
            await latch.open()
            await session.close()
        }
        let feed = await session.streamSessionEvents()

        let held = try await MailQueueFixtures.startHeldAnswer(Self.heldPrompt, on: session, backend: backend)
        let streamed = Self.stream(Self.firstPrompt)
        _ = try session.mail(streamed)
        let reply = try session.send(Self.secondPrompt)
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        #expect(backend.prompts == [Self.heldPrompt, Self.firstPrompt, Self.secondPrompt])
        let events = await Self.events(of: feed)
        #expect(events.answers.map(\.mailIds) == [[held], [streamed.id], [reply]])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [held, streamed.id, reply])
        withExtendedLifetime(profile) {}
    }

    @Test("the max tokens are part of the key: two replies with different ceilings are two answers, two with the same ceiling are one")
    func theCeilingSplitsTheAnswers() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer {
            await latch.open()
            await session.close()
        }
        let feed = await session.streamSessionEvents()

        let held = try await MailQueueFixtures.startHeldAnswer(Self.heldPrompt, on: session, backend: backend)
        let small = Self.reply(Self.firstPrompt, maxTokens: Self.smallCeiling)
        let large = Self.reply(Self.secondPrompt, maxTokens: Self.largeCeiling)
        let sameAsSmall = Self.reply(Self.thirdPrompt, maxTokens: Self.smallCeiling)
        for mail in [small, large, sameAsSmall] {
            _ = try session.mail(mail)
        }
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        #expect(
            backend.prompts == [
                Self.heldPrompt, Self.firstPrompt + RoutedSessionActor.messageSeparator + Self.thirdPrompt,
                Self.secondPrompt,
            ])
        let events = await Self.events(of: feed)
        #expect(events.answers.map(\.mailIds) == [[held], [small.id, sameAsSmall.id], [large.id]])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [held, small.id, large.id, sameAsSmall.id])
        withExtendedLifetime(profile) {}
    }

    @Test("run mail that arrives while an answer runs joins its continuation, and the end of the answer names it")
    func runMailJoinsTheContinuation() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer.
        let backend = Backend(script: [1: .holdThenReject(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer {
            await latch.open()
            await session.close()
        }
        let feed = await session.streamSessionEvents()

        let held = try await MailQueueFixtures.startHeldAnswer(Self.heldPrompt, on: session, backend: backend)
        let event = MailQueueFixtures.progressEvent(detail: "the run goes on")
        let runMail = try await MailQueueFixtures.post(event, to: session)
        await latch.open()
        let terminal = try await session.awaitTerminal(of: held)
        #expect(await session.becomesIdle())
        await session.close()

        let answer = try #require(MailQueueFixtures.answer(of: terminal), "the held message ended with \(terminal)")
        #expect(answer.mailIds == [held, runMail])
        #expect(backend.prompts.count == 2)
        #expect(backend.prompts.last?.contains(OperationEventSegment.renderedLine(for: event)) == true)
        let events = await Self.events(of: feed)
        let starts = events.submissionStarts
        #expect(starts.map(\.cause) == [.message, .continuation])
        #expect(events.contains(.mailDelivered(runMail)))
        #expect(session.outbox.queue.pending.isEmpty)
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [held, runMail])
        withExtendedLifetime(profile) {}
    }

    // MARK: - Progress mail

    @Test("two progress events with the same key make one queued mail, and its event is the latest")
    func progressCoalescesInPlace() async throws {
        let outbox = SessionOutbox()
        let first = MailQueueFixtures.progressEvent(detail: "ten percent")
        let latest = MailQueueFixtures.progressEvent(detail: "fifty percent")
        let otherRun = MailQueueFixtures.progressEvent(detail: "other run", correlationID: "another-run")

        await outbox.post(event: first)
        let firstID = try #require(outbox.queue.pending.first?.id)
        await outbox.post(event: latest)
        await outbox.post(event: otherRun)

        let pending = outbox.pendingRunMail
        #expect(pending.count == 2)
        #expect(pending.first?.id == firstID)
        #expect(pending.first?.event == latest)
        #expect(pending.last?.event == otherRun)
        #expect(outbox.queue.pending.count == 2)
    }

    @Test("a queue that holds only progress mail starts no answer, and the pump ends and does not loop")
    func onlyProgressMailStartsNoAnswer() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer { await session.close() }
        let feed = await session.streamSessionEvents()

        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "a step of the run"), to: session)
        // A progress post wakes no pump, so the test wakes it, as new mail
        // does. The wake starts the pump before it returns, so the wait
        // below reads the end of that pump. Nothing else wakes a pump after
        // it, so the reads after its end are final.
        await (session as! RoutedSessionActor).wakePump()
        #expect(await session.pumpEnds())

        #expect(await session.isPumpRunning == false)
        #expect(backend.prompts.isEmpty)
        #expect(session.outbox.queue.pending.map(\.id) == [runMail])
        await session.close()

        let events = await Self.events(of: feed)
        #expect(!events.contains(where: MailQueueFixtures.isSubmissionStart))
        #expect(!events.contains(.mailDelivered(runMail)))
        // The close cancels the mail that is still in the queue.
        #expect(MailQueueFixtures.cancelledIds(in: events) == [runMail])
        TerminalEventLedger(events: events).expectExactlyOneTerminal(for: [runMail])
        withExtendedLifetime(profile) {}
    }
}
