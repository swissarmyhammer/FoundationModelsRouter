import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the leases that the work of a session holds in its work
/// registry, and the work events that the registry drives.
///
/// The work of a session is the set of the open leases of its registry: the
/// generation of an answer, each queued mail that can start an answer, a
/// requested compaction, a relayed child that works, and each lease of a
/// tool. ``SessionEvent/workStarted`` comes when the first lease opens, and
/// ``SessionEvent/workEnded`` comes when the last lease ends.
///
/// Each test reads the work events of a feed up to the end of the feed:
/// the test waits until the session is idle (``RoutedSession/awaitIdle()``),
/// closes the session, and then reads the rest of the feed. A close gives
/// no work event, so a session that does not send its work-end event before
/// the close fails the test, and no wait hangs.
///
/// Everything runs against the scripted ``BackgroundingBackend``, so the
/// suite needs no network and no GPU.
@Suite("The leases of the work of a session drive its work events")
struct SessionWorkLeaseTests {
    // MARK: - Fixtures

    /// A tool that records the kinds of the open leases of the registry of
    /// its session while it runs, and holds one short lease of its own
    /// inside the call.
    struct OpenWorkRecordingTool: Tool {
        let name = "open_work_recording_job"
        let description = "test-only tool that records the open work of its session"

        /// The kinds of the open leases at each call, in call order.
        static let recorded = Mutex<[[WorkKind]]>([])

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            await context.withBackgroundWork(.innerCall, id: "short") {
                let kinds = context.runPlane.workRegistry.openWork.map(\.kind)
                Self.recorded.withLock { $0.append(kinds) }
            }
            return "recorded"
        }
    }

    // MARK: - Constants

    /// The prompt of each caller message.
    private static let jobPrompt = "run the job"

    /// The output of a latched background run.
    private static let runOutput = "the job is done"

    /// The work events of one piece of work.
    private static let onePair: [SessionEvent] = [.workStarted, .workEnded]

    /// The kind of the lease of a generation.
    private static let generation = WorkKind("generation")

    /// The kind of the lease of a queued mail.
    private static let mail = WorkKind("mail")

    /// The kind of the lease of a requested compaction.
    private static let compaction = WorkKind("compaction")

    // MARK: - Helpers

    /// Makes a session with `tools` over the backend that `container` vends.
    ///
    /// - Parameters:
    ///   - tools: The tools of the session.
    ///   - container: The container that vends the backend.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    private static func makeFixture(
        tools: [any Tool] = [], container: BackgroundingLLMContainer = BackgroundingLLMContainer()
    ) async throws -> BackgroundingSessionFixture {
        try await BackgroundingSessionFixture.make(prefix: "SessionWorkLeaseTests", tools: tools, container: container)
    }

    /// Waits until `session` is idle, closes it, and reads `feed` to its end.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - feed: The iterator of a feed of the session.
    /// - Returns: Each output that the feed gave after the earlier reads.
    static func outputsToTheClose(
        of session: any RoutedSession, feed: inout AsyncStream<SessionOutput>.Iterator
    ) async -> [SessionOutput] {
        #expect(await session.awaitIdle())
        await session.close()
        return await SessionWorkEventTests.remainingOutputs(of: &feed)
    }

    /// The work events of `outputs`, in order.
    ///
    /// - Parameter outputs: Outputs of a session.
    /// - Returns: Each work event.
    static func workEvents(of outputs: [SessionOutput]) -> [SessionEvent] {
        SessionWorkEventTests.workEvents(of: outputs)
    }

    /// The kinds of the open leases of the registry of `session`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The kinds, in begin order.
    static func openKinds(of session: any RoutedSession) -> [WorkKind] {
        session.runPlane.workRegistry.openWork.map(\.kind)
    }

    // MARK: - The leases of the work of the session

    /// The production change that makes this test fail: an answer that holds
    /// no lease. A short lease of a tool inside the answer is then the only
    /// open lease, and its end gives a work-end event inside the answer.
    @Test("an answer holds one generation lease for its whole run, so a short lease of a tool inside it ends no work")
    func anAnswerHoldsAGenerationLease() async throws {
        OpenWorkRecordingTool.recorded.withLock { $0 = [] }
        let fixture = try await Self.makeFixture(tools: [OpenWorkRecordingTool()])
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let outputs = await SessionWorkEventTests.outputs(throughNextWorkEnd: &feed)

        let recorded = OpenWorkRecordingTool.recorded.withLock { $0 }
        #expect(recorded == [[Self.generation, .innerCall]])
        #expect(Self.workEvents(of: outputs) == Self.onePair)
        let answered = try position(ofFirst: .answered, in: outputs)
        #expect(answered == outputs.count - 2)
        #expect(Self.openKinds(of: fixture.session).isEmpty)
    }

    /// The production change that makes this test fail: a cancel of the
    /// last queued user mail that reports no change of the work. The session
    /// then has no work, and sends no work-end event.
    @Test("a queued user mail holds one mail lease, and a cancel of the last one ends the work with one work-end event")
    func aCancelOfTheLastUserMailEndsTheWork() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        // The pause holds the mail in the queue: no pump takes it.
        fixture.session.outbox.queue.pause()
        let id = try fixture.session.send(Self.jobPrompt)
        #expect(Self.openKinds(of: fixture.session) == [Self.mail])

        _ = try await fixture.session.awaitTerminal(of: fixture.session.cancel(id))
        let outputs = await Self.outputsToTheClose(of: fixture.session, feed: &feed)

        #expect(Self.workEvents(of: outputs) == Self.onePair)
        let cancelled = try #require(outputs.firstIndex { $0.event == .cancelled(id) })
        let ended = try #require(outputs.firstIndex { $0.event == .workEnded })
        #expect(cancelled < ended)
    }

    /// The production change that makes this test fail: a withdraw of queued
    /// run mail that reports no change of the work. The withdrawn message
    /// was the last work of the session, and no work-end event comes.
    @Test("a run message that can start an answer holds a mail lease, and its withdraw ends the work with one work-end event")
    func aWithdrawOfTheLastRunMailEndsTheWork() async throws {
        let fixture = try await Self.makeFixture()
        let gate = RunLatch()
        defer { await fixture.end(opening: [gate]) }
        let session = fixture.session
        await session.attachOutboxJournal()
        var feed = await session.streamSessionEvents().makeAsyncIterator()
        // The pause holds the mail in the queue: no pump takes it.
        session.outbox.queue.pause()
        let token = await trackFakeRun(on: session.runPlane, latch: gate)
        let message = OperationEvent(
            tool: FakeRun.tool, op: FakeRun.op, correlationID: token, kind: .message, detail: "a message")
        let messageId = try await MailQueueFixtures.post(message, to: session)
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: token, in: session.runPlane)
        #expect(Self.openKinds(of: session) == [Self.mail])

        await session.outbox.withdrawStagedEvents(correlationID: token)
        let outputs = await Self.outputsToTheClose(of: session, feed: &feed)

        #expect(Self.workEvents(of: outputs) == Self.onePair)
        #expect(MailQueueFixtures.cancelledIds(in: outputs.map(\.event)) == [messageId])
    }

    /// The production change that makes this test fail: a requested
    /// compaction that takes no lease.
    @Test("a requested compaction holds one compaction lease from the request to its end")
    func aRequestedCompactionHoldsALease() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        let signal = fixture.session.compact(prompt: .default, budget: nil)
        let openAtTheRequest = Self.openKinds(of: fixture.session)
        _ = try? await fixture.session.awaitTerminal(of: signal)
        let outputs = await Self.outputsToTheClose(of: fixture.session, feed: &feed)

        #expect(openAtTheRequest == [Self.compaction])
        #expect(Self.workEvents(of: outputs) == Self.onePair)
    }

    /// The production change that makes this test fail: a relay that opens
    /// with a working child and notes no start of work. The session then
    /// has work with no work-start event.
    @Test("a relay whose child works at its open holds one lease until the child stops")
    func aRelayWithAWorkingChildHoldsALease() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        let session = try fixture.sessionActor()
        let child = try await fixture.session.fork(workingDirectory: nil)
        defer { await child.close() }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        let relay = await session.openRelay(child: child, childWorks: true)
        let openWhileTheChildWorks = Self.openKinds(of: fixture.session)
        await session.noteChild(of: relay, works: false)
        await session.closeRelay(relay)
        let outputs = await Self.outputsToTheClose(of: fixture.session, feed: &feed)

        #expect(openWhileTheChildWorks == [WorkKind("relayedChild")])
        #expect(Self.workEvents(of: outputs) == Self.onePair)
    }

    // MARK: - The sequence of a background run that settles inside an answer

    /// The sequence of a bench run: the answer to a prompt starts a
    /// background run; the run settles while that answer still runs; the
    /// answer ends; then an answer to the run mail alone runs. The session
    /// has work from the prompt to the end of the second answer, so it sends
    /// one work-end event, after the second answer.
    @Test("a run that settles inside the answer that started it gives one work-end event, after the answer to its mail")
    func aRunThatSettlesInsideItsAnswerGivesOneWorkEnd() async throws {
        let gate = RunLatch()
        let holdFirstAnswer = RunLatch()
        let fixture = try await Self.makeFixture(
            tools: [LatchedBackgroundToolRunner(name: "pending_job", gate: gate, output: Self.runOutput)],
            container: BackgroundingLLMContainer(holdFirstAnswer: holdFirstAnswer))
        defer { await fixture.end(opening: [gate, holdFirstAnswer]) }
        var feed = await fixture.session.streamSessionEvents().makeAsyncIterator()

        let answering = Task { try await fixture.session.respond(to: Self.jobPrompt) }
        try await fixture.backend.changes.wait(
            until: { fixture.backend.toolOutputs.count == 1 }, endingOnEndOf: answering)
        let envelope = try #require(PendingRunEnvelope.makeDecoded(fromRendered: fixture.backend.toolOutputs[0]))
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: envelope.completionToken, in: fixture.session.runPlane)
        await holdFirstAnswer.open()
        _ = try await answering.value
        let outputs = await SessionWorkEventTests.outputs(throughNextWorkEnd: &feed)

        #expect(Self.workEvents(of: outputs) == Self.onePair)
        let answers = outputs.indices.filter { SessionEventCase.answered.matches(outputs[$0].event) }
        #expect(answers.count == 2)
        #expect(answers.last == outputs.count - 2)
        #expect(fixture.backend.receivedPrompts.last?.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt) == true)
    }

    // MARK: - One registry for each session

    /// The production change that makes this test fail: work events that do
    /// not come from the registry of the session, or a fork that shares the
    /// registry of its parent.
    @Test("a lease of a fork never makes its parent busy, and each session gives its own work events")
    func aForkLeaseNeverMakesItsParentBusy() async throws {
        let fixture = try await Self.makeFixture()
        defer { await fixture.end() }
        let child = try await fixture.session.fork(workingDirectory: nil)
        defer { await child.close() }
        var parentFeed = await fixture.session.streamSessionEvents().makeAsyncIterator()
        var childFeed = await child.streamSessionEvents().makeAsyncIterator()

        let childLease = child.runPlane.workRegistry.begin(.shellCommand, id: "a child command")
        let parentHadWork = fixture.session.runPlane.workRegistry.hasWork
        childLease.end()
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        let childOutputs = await Self.outputsToTheClose(of: child, feed: &childFeed)
        let parentOutputs = await Self.outputsToTheClose(of: fixture.session, feed: &parentFeed)

        #expect(parentHadWork == false)
        #expect(Self.workEvents(of: childOutputs) == Self.onePair)
        #expect(Self.workEvents(of: parentOutputs) == Self.onePair)
    }

    /// The production change that makes this test fail: a background run of
    /// a fork whose lease goes into the registry of the parent.
    @Test("a background run of a fork holds its lease in the registry of the fork only")
    func aRunOfAForkHoldsItsLeaseInTheFork() async throws {
        let fixture = try await Self.makeFixture()
        let gate = RunLatch()
        defer { await fixture.end(opening: [gate]) }
        let child = try await fixture.session.fork(workingDirectory: nil)
        defer { await child.close() }

        let token = await trackFakeRun(on: child.runPlane, latch: gate)
        let childKinds = Self.openKinds(of: child)
        let parentKinds = Self.openKinds(of: fixture.session)
        await gate.open()
        _ = try await MountFixtures.settledTerminal(of: token, in: child.runPlane)

        #expect(childKinds == [.backgroundRun])
        #expect(parentKinds.isEmpty)
        #expect(Self.openKinds(of: child).isEmpty)
    }
}
