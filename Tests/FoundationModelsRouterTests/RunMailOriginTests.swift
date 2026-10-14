import Foundation
import FoundationModels
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Exercises the origin of the output events of run mail (`mailbox.md`,
/// section 5, problem 15, "Gap found at the start of step 3"; mail step 2,
/// part G).
///
/// Each ``OperationEvent`` that a run posts to the outbox of a session becomes
/// one run mail with a ``MailID``. The output event of the run event
/// (``SessionEvent/runMessage(_:)``, ``SessionEvent/runSettled(_:)``,
/// ``SessionEvent/runProgress(_:)`` or ``SessionEvent/elicitationRequested(_:)``)
/// has the origin ``Origin/mail(_:)`` with that id. Thus a reader can wait for
/// the ``SessionEvent/mailDelivered(_:)`` of the same id, and find the id in
/// the ``SessionAnswer/mailIds`` of the answer that delivered it. A progress
/// event that replaces queued progress mail has the id of that mail. A run
/// event that makes no mail keeps the origin of the work that posted it.
///
/// Each test runs in a fixed order: it waits only for the end of a call, an
/// element of a stream or a latch. No test reads a clock, sleeps, polls or
/// retries. Everything runs on ``SessionMessagePumpTests/PumpProbeBackend``,
/// so the suite needs no network and no GPU.
@Suite("The output event of each run event has the id of its run mail as its origin")
struct RunMailOriginTests {
    /// The backend the suite scripts.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "RunMailOriginTests"

    /// The prompt of the caller message whose answer delivers the run mail.
    private static let prompt = "what did the run say"

    /// The prompt of the caller message whose answer `cancelAll()` stops.
    private static let stoppedPrompt = "start the work that is stopped"

    /// The completion token of the probe run. No background run of a session
    /// has it, so the run mail of the probe run starts no answer by itself:
    /// it rides the next caller message.
    private static let runToken = "run-mail-origin-probe"

    // MARK: - Fixtures

    /// Makes one event of the probe run.
    ///
    /// - Parameters:
    ///   - kind: The kind of the event.
    ///   - detail: The detail of the event.
    /// - Returns: The event.
    private static func runEvent(_ kind: OperationEventKind, detail: String) -> OperationEvent {
        OperationEvent(
            tool: MailQueueFixtures.runTool, op: MailQueueFixtures.runOp, correlationID: runToken, kind: kind,
            detail: detail)
    }

    /// Makes a session over `backend` that records into `recorder`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The cache directory of the router.
    ///   - recorder: The recorder of the router.
    /// - Returns: The session, and the router and the profile that keep its
    ///   model resident.
    private static func makeSession(
        over backend: Backend, dir: URL, recorder: any TranscriptRecorder = InMemoryRecorder()
    ) async throws -> (session: any RoutedSession, keep: (Router, LanguageModelProfile)) {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir, recorder: recorder,
            loader: StubModelLoader(
                container: SessionMessagePumpTests.PumpProbeContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile.standard.makeSession(), (router, profile))
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

    /// Posts `events` to the outbox of a new session, one after the other,
    /// then sends one caller message, whose answer delivers the run mail, and
    /// closes the session.
    ///
    /// Each post returns after the journal wrote its event, so the output
    /// event of each run event comes before the answer.
    ///
    /// - Parameter events: The run events to post, in order.
    /// - Returns: Each output of the session, in order.
    private static func outputs(posting events: [OperationEvent]) async throws -> [SessionOutput] {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (session, keep) = try await makeSession(over: Backend(script: [:]), dir: dir)
        let feed = await session.streamSessionEvents()
        await session.attachOutboxJournal()

        for event in events {
            await session.outbox.post(event: event)
        }
        _ = try await session.respond(to: prompt)
        await session.close()

        let outputs = await collectOutputs(feed)
        withExtendedLifetime(keep) {}
        return outputs
    }

    /// The one id of `origin`.
    ///
    /// - Parameter origin: The origin of one output event.
    /// - Returns: The id, or `nil` when `origin` is not ``Origin/mail(_:)``
    ///   with exactly one id.
    private static func soleMailID(of origin: Origin) -> MailID? {
        guard case .mail(let ids) = origin, ids.count == 1 else { return nil }
        return ids.first
    }

    /// The index of the first output of `outputs` whose event is `event`.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - outputs: The output of a session, in order.
    /// - Returns: The index.
    /// - Throws: When `outputs` does not have the event.
    private static func index(of event: SessionEvent, in outputs: [SessionOutput]) throws -> Int {
        try #require(outputs.firstIndex { $0.event == event }, "the output has no \(event)")
    }

    /// Checks that the one output of `event` has the origin of one run mail,
    /// and that the answer delivered that mail and ended it.
    ///
    /// The checks: exactly one output holds `event`; its origin is
    /// ``Origin/mail(_:)`` with one id; exactly one
    /// ``SessionEvent/mailDelivered(_:)`` has that id; the
    /// ``SessionAnswer/mailIds`` of the one answer hold that id; and the id
    /// has exactly one terminal event.
    ///
    /// - Parameters:
    ///   - event: The output event of the run event.
    ///   - outputs: The output of a session, in order.
    ///   - sourceLocation: The place of the call, for the issue.
    /// - Returns: The id of the run mail.
    /// - Throws: When an output that the checks read is missing.
    @discardableResult
    private static func expectRunMailOrigin(
        of event: SessionEvent, in outputs: [SessionOutput], sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> MailID {
        let matching = outputs.filter { $0.event == event }
        #expect(matching.count == 1, "\(matching.count) outputs hold \(event)", sourceLocation: sourceLocation)
        let output = try #require(matching.first, sourceLocation: sourceLocation)
        let id = try #require(
            soleMailID(of: output.origin), "the origin of \(event) is \(output.origin)",
            sourceLocation: sourceLocation)
        #expect(
            outputs.filter { $0.event == .mailDelivered(id) }.count == 1,
            "the run mail \(id) has no single delivery", sourceLocation: sourceLocation)
        let answers = outputs.map(\.event).answers
        #expect(answers.count == 1, sourceLocation: sourceLocation)
        #expect(answers.first?.mailIds.contains(id) == true, sourceLocation: sourceLocation)
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [id])
        return id
    }

    // MARK: - The id of the run mail

    /// The production change that makes this test fail: the output event of
    /// a run message that has no mail origin, or the origin of another mail
    /// than the run mail that the answer delivers.
    @Test("a runMessage has the id of its run mail; the later mailDelivered and the answer have the same id")
    func aRunMessageHasTheIdOfItsRunMail() async throws {
        let message = Self.runEvent(.message, detail: "half of the files are done")

        let outputs = try await Self.outputs(posting: [message])

        let id = try Self.expectRunMailOrigin(of: .runMessage(message), in: outputs)
        #expect(try Self.index(of: .runMessage(message), in: outputs) < Self.index(of: .mailDelivered(id), in: outputs))
    }

    /// The production change that makes this test fail: the output event of
    /// a run terminal that has no mail origin, or the origin of another mail
    /// than the run mail that the answer delivers.
    @Test("a runSettled has the id of its run mail; the later mailDelivered and the answer have the same id")
    func aRunSettledHasTheIdOfItsRunMail() async throws {
        let terminal = Self.runEvent(.completed, detail: "all of the files are done")

        let outputs = try await Self.outputs(posting: [terminal])

        let id = try Self.expectRunMailOrigin(of: .runSettled(terminal), in: outputs)
        #expect(try Self.index(of: .runSettled(terminal), in: outputs) < Self.index(of: .mailDelivered(id), in: outputs))
    }

    /// The production change that makes this test fail: the output event of
    /// an elicitation that has no mail origin, or the origin of another mail
    /// than the run mail that the answer delivers.
    @Test("an elicitationRequested has the id of its run mail; the later mailDelivered and the answer have the same id")
    func anElicitationRequestedHasTheIdOfItsRunMail() async throws {
        let elicitation = Self.runEvent(.elicitation, detail: "which folder")

        let outputs = try await Self.outputs(posting: [elicitation])

        let id = try Self.expectRunMailOrigin(of: .elicitationRequested(elicitation), in: outputs)
        #expect(
            try Self.index(of: .elicitationRequested(elicitation), in: outputs)
                < Self.index(of: .mailDelivered(id), in: outputs))
    }

    /// The production change that makes this test fail: a progress event
    /// that replaces queued progress mail and gets a new id, or no mail
    /// origin, in place of the id of the queued mail.
    @Test("a progress event that replaces queued progress mail has the id of the queued mail")
    func aCoalescedProgressHasTheQueuedId() async throws {
        let first = Self.runEvent(.progress, detail: "10%")
        let latest = Self.runEvent(.progress, detail: "50%")

        let outputs = try await Self.outputs(posting: [first, latest])

        let id = try Self.expectRunMailOrigin(of: .runProgress(first), in: outputs)
        let replacing = try #require(outputs.first { $0.event == .runProgress(latest) })
        #expect(replacing.origin == .mail([id]))
        // The answer delivers the caller message and the one progress mail.
        #expect(outputs.map(\.event).answers.first?.mailIds.count == 2)
    }

    /// The production change that makes this test fail: a run event of a
    /// stopped run that makes mail, or whose output event has another origin
    /// than the work that posted it.
    @Test("a run event of a stopped run makes no mail, and its output event keeps the origin of the work that posted it")
    func aStoppedRunGivesNoMailId() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (session, keep) = try await Self.makeSession(over: Backend(script: [:]), dir: dir)
        let feed = await session.streamSessionEvents()
        await session.attachOutboxJournal()
        let message = Self.runEvent(.message, detail: "late message of a stopped run")
        let poster = Origin.mail([MailID()])

        session.outbox.ignoreRunMail(of: [Self.runToken])
        await OriginContext.$current.withValue(poster) {
            await session.outbox.post(event: message)
        }

        #expect(session.outbox.queue.pending.isEmpty)
        await session.close()
        let outputs = await Self.collectOutputs(feed)
        #expect(outputs.filter { $0.event == .runMessage(message) }.map(\.origin) == [poster])
        #expect(!outputs.contains { if case .mailDelivered = $0.event { true } else { false } })
        withExtendedLifetime(keep) {}
    }

    /// The production change that makes this test fail: the output event of
    /// a run event that the stopped answer posted, after
    /// ``RoutedSession/cancelAll()`` stopped that answer, reaches the output
    /// because it has the origin of its new run mail.
    @Test("after cancelAll() stopped an answer, a run event that the work of that answer posts sends no output event")
    func aRunEventOfAStoppedAnswerSendsNoOutput() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let (session, keep) = try await Self.makeSession(over: Backend(script: [1: .hold(latch)]), dir: dir)
        let feed = await session.streamSessionEvents()
        var reader = feed.makeAsyncIterator()
        let stopped = try session.send(Self.stoppedPrompt)
        var outputs: [SessionOutput] = []
        while let output = await reader.next() {
            outputs.append(output)
            if MailQueueFixtures.isSubmissionStart(output.event) { break }
        }
        let stop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stop) == .signalDone(stop))
        #expect(await session.isIdleOnceThePumpEnds())
        let message = Self.runEvent(.message, detail: "late message of the stopped answer")

        await OriginContext.$current.withValue(.mail([stopped])) {
            await session.outbox.post(event: message)
        }

        await session.close()
        while let output = await reader.next() {
            outputs.append(output)
        }
        #expect(!outputs.contains { $0.event == .runMessage(message) }, "\(outputs)")
        TerminalEventLedger(outputs: outputs).expectExactlyOneTerminal(for: [stopped])
        withExtendedLifetime(keep) {}
    }

    // MARK: - The order of the delivery and the output event

    /// The production change that makes this test fail: an output event of a
    /// run message that has no mail origin, or another id than the
    /// ``SessionEvent/mailDelivered(_:)`` that came before it.
    ///
    /// The order can occur: ``SessionOutbox/post(event:)`` puts the run mail
    /// into the queue at once, and the journal writes the event and sends
    /// its output event later, on its own chain. A pump that takes the mail
    /// meanwhile sends ``SessionEvent/mailDelivered(_:)`` first. The test
    /// holds the transcript write of the run event, so the order is fixed.
    @Test("when the answer delivers the run mail before the journal sends the runMessage, both have the same id")
    func aDeliveryBeforeTheRunMessageHasTheSameId() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = RunRowGateRecorder()
        let (session, keep) = try await Self.makeSession(over: Backend(script: [:]), dir: dir, recorder: recorder)
        let feed = await session.streamSessionEvents()
        await session.attachOutboxJournal()
        let message = Self.runEvent(.message, detail: "a message that the journal holds")

        let posting = Task { await session.outbox.post(event: message) }
        await recorder.entered.waitUntilOpen()
        _ = try await session.respond(to: Self.prompt)
        await recorder.gate.open()
        await posting.value
        await session.close()

        let outputs = await Self.collectOutputs(feed)
        let id = try Self.expectRunMailOrigin(of: .runMessage(message), in: outputs)
        #expect(try Self.index(of: .mailDelivered(id), in: outputs) < Self.index(of: .runMessage(message), in: outputs))
        withExtendedLifetime(keep) {}
    }
}

/// A recorder that holds the first transcript row of a run event
/// (``TranscriptEvent/Kind/toolOutput``) until a test opens ``gate``. Each
/// other event goes on at once to an ``InMemoryRecorder``.
///
/// The run journal writes the row before it sends the output event of the run
/// event, so the hold keeps the output event back while the rest of the
/// session works.
private actor RunRowGateRecorder: TranscriptRecorder {
    /// Opens when the first run event row arrives and waits at ``gate``.
    let entered = RunLatch()

    /// The test opens it to let the held row go on.
    let gate = RunLatch()

    /// The recorder that keeps each event.
    private let inner = InMemoryRecorder()

    /// Whether a run event row was held.
    private var didHoldARow = false

    /// Keeps `partial` in ``inner``. The first run event row waits at
    /// ``gate`` first, after it opened ``entered``.
    ///
    /// - Parameters:
    ///   - partial: The event to record.
    ///   - directory: The session directory, which ``inner`` ignores.
    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        if partial.kind == .toolOutput, !didHoldARow {
            didHoldARow = true
            await entered.open()
            await gate.waitUntilOpen()
        }
        await inner.append(partial, to: directory)
    }
}
