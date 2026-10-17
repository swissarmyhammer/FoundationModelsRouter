import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RecordedWaitResult/wait(forPermitOf:endingOnTerminalOf:on:sourceLocation:)``:
/// the wait for a permit that also ends on the terminal event of a mail (rule
/// T1). The end of that wait must not change the mail. Each test runs in a
/// fixed order, with no clock. The session runs on the stub backend of the
/// mail queue, so the suite needs no network and no GPU.
@Suite("The wait for a permit that ends on the terminal event of a mail does not cancel the mail")
struct MailTerminalPermitWaitTests {
    /// The prefix of the temporary directory of each test.
    private static let tempDirPrefix = "mail-terminal-permit-wait"

    /// The prompt of the answer that the backend holds.
    private static let heldPrompt = "held-question"

    /// The prompt of the message that waits in the queue behind the held
    /// answer.
    private static let queuedPrompt = "queued-question"

    /// The production change that makes this test fail: a wait that ends on
    /// the terminal event through ``RoutedSession/awaitTerminal(of:)-(MailID)``
    /// in a task that the helper cancels. A cancel of that wait also cancels
    /// the mail, so the queued mail gets ``SessionEvent/cancelled(_:)``, and
    /// the feed gets a ``SessionEvent/signalDone(_:)`` of a signal that the
    /// test did not send.
    @Test("a permit that comes first ends the wait, and the queued mail stays in the queue")
    func aPermitThatComesFirstLeavesTheMailQueued() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let latch = RunLatch()
        let backend = MailQueueFixtures.Backend(script: [1: .hold(latch)])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer {
            await latch.open()
            await session.close()
        }
        let hub = (session as! RoutedSessionActor).outputHub
        let feed = await session.streamSessionEvents()
        try await MailQueueFixtures.startHeldAnswer(Self.heldPrompt, on: session, backend: backend)
        // The held answer runs, so the message waits in the queue. Only a
        // cancel of the mail can end it before the latch opens.
        let queued = try session.send(Self.queuedPrompt)
        let permit = AsyncSemaphore(value: 0)

        let waiting = Task {
            try await RecordedWaitResult.wait(forPermitOf: permit, endingOnTerminalOf: queued, on: session)
        }
        defer { waiting.cancel() }
        // The permit comes only after the wait for the terminal event is in
        // the hub. Thus the end of the wait cancels a wait that is open, and
        // a cancel signal that the end sends goes into the signal chain
        // before the wait returns.
        try await hub.waiterChanges.wait(until: { hub.waiterCount > 0 }, endingOnEndOf: waiting)
        permit.signal()
        try await waiting.value

        // The signals run in order. When the probe ended, each signal that
        // the wait sent also ended.
        let probe = session.cancel(MailID())
        #expect(try await session.awaitTerminal(of: probe) == .signalDone(probe))
        #expect(hub.terminal(for: .mail(queued)) == nil)

        // The close finishes the feed. The probe is the one signal of the
        // test, so the feed has no other end of a signal.
        await latch.open()
        await session.close()
        let events = await collect(feed.events)
        #expect(TerminalEventLedger(events: events).endedSignalIds == [probe.description])
        withExtendedLifetime(profile) {}
    }
}
