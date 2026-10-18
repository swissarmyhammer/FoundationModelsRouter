import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises a background call that waits for its own run outside an answer
/// of the session, for example an inner call of a script run: the run
/// settles inside the settle period, and the call answers with the result.
/// The staged mail of the run must then never reach the model a second
/// time, also when the pump of the session is free at the settlement.
///
/// The test calls the mounted tool itself, so no answer runs and the pump
/// is free. The call posts to the outbox of the session through a sink that
/// holds back each withdraw after the settlement while mail of the run
/// waits (``CallWithdrawGate``), so the settlement of the run comes to the
/// session before such a withdraw.
/// The run plane runs on a `ManualRunClock` that the test never advances, so
/// the settle period never ends.
@Suite("A run that settles inside the settle period of its call gives no mail")
struct InlineRunWithdrawRaceTests {
    // MARK: - Fixtures

    /// A background tool whose run waits for its gate and then returns.
    struct GatedInlineTool: Tool, BackgroundTool {
        let name = "gated_inline_job"
        let description = "test-only background tool whose run waits for its gate"

        /// The gate the body of the run waits on.
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        var inlineSettleGrace: TimeInterval {
            MountFixtures.manualClockGrace
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            await gate.waitUntilOpen()
            return InlineRunWithdrawRaceTests.runOutput
        }
    }

    /// A sink that gives each post to the outbox of the session, and holds
    /// back until ``gate`` opens each withdraw that comes after the run
    /// plane settled the run while staged mail of the run waits. A withdraw
    /// before the settlement goes to the outbox at once.
    struct CallWithdrawGate: OperationEventSink, ToolCallReportSink, StagedEventWithdrawing {
        /// The outbox of the session.
        let outbox: SessionOutbox

        /// The run plane of the session.
        let runPlane: RunPlane

        /// The gate that holds back each withdraw after the settlement.
        let gate: RunLatch

        func post(event: OperationEvent) async {
            await outbox.post(event: event)
        }

        func post(invocation record: ToolInvocationRecord) async {
            await outbox.post(invocation: record)
        }

        func post(display event: ToolDisplayEvent) async {
            await outbox.post(display: event)
        }

        func post(elicitationCompleted elicitationId: ULID) async {
            await outbox.post(elicitationCompleted: elicitationId)
        }

        func post(elicitationEnded elicitationId: ULID, response: ElicitationResponse) async {
            await outbox.post(elicitationEnded: elicitationId, response: response)
        }

        func post(report: ToolCallReport) async {
            await outbox.post(report: report)
        }

        func withdrawStagedEvents(correlationID: String) async {
            let mailWaits = outbox.queue.pending.contains { $0.runEvent?.correlationID == correlationID }
            if mailWaits, await runPlane.settledRunTokens().contains(correlationID) {
                await gate.waitUntilOpen()
            }
            await outbox.withdrawStagedEvents(correlationID: correlationID)
        }
    }

    // MARK: - Constants

    /// The output of the run.
    static let runOutput = "the job is done"

    // MARK: - Tests

    /// The production change that makes this test fail: a withdraw of the
    /// staged mail that the call does after the run settled. The settlement
    /// wakes the free pump, and the pump takes the mail first, so the model
    /// gets the result a second time in a mail answer.
    @Test("a run that settles inside the settle period of a call outside an answer gives no mail answer, and its mail ends cancelled")
    func anInlineRunGivesNoMailAnswer() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "InlineRunWithdrawRaceTests")
        let container = BackgroundingLLMContainer()
        let clock = ManualRunClock()
        let (router, profile) = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            try await RouterTestFixtures.resolveStandardProfile(over: container, cacheDir: directory, runClock: clock)
        }
        let session = profile.standard.makeSession()
        let runGate = RunLatch()
        let withdrawGate = RunLatch()
        defer {
            await runGate.open()
            await withdrawGate.open()
            await session.close()
            try? FileManager.default.removeItem(at: directory)
            withExtendedLifetime(router) {}
        }
        let backend = try #require(container.lastBackend)
        await session.attachOutboxJournal()
        var feed = await session.streamSessionEvents().makeAsyncIterator()
        let mounted = ToolMounting.makeSessionMounted(
            tool: GatedInlineTool(gate: runGate), sessionID: session.id, runPlane: session.runPlane,
            sink: CallWithdrawGate(outbox: session.outbox, runPlane: session.runPlane, gate: withdrawGate),
            cappedToTokenLimit: nil,
            tokenCounter: CharacterTokenCounter(), inlineSettleGrace: MountFixtures.manualClockGrace)
        let tool = try #require([mounted].fixtureTools.first)

        let calling = Task { try await tool.call(arguments: BackgroundFixtureArguments(value: "go")) }
        let callEnded = RecordedWaitResult.recordingEnd(of: calling, reportingTo: backend.changes)
        defer { callEnded.stopRecording() }
        try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: calling)
        await runGate.open()
        // A mail answer gives a prompt while the withdraw of the call waits.
        // A call that withdrew inside its run ends with no prompt.
        try await backend.changes.wait(until: { !backend.receivedPrompts.isEmpty || callEnded.value != nil })
        await withdrawGate.open()
        let answer = try await calling.value
        #expect(await session.awaitIdle())
        await session.close()
        let outputs = await SessionWorkEventTests.remainingOutputs(of: &feed)

        #expect(answer == Self.runOutput)
        #expect(backend.receivedPrompts.isEmpty)
        let events = outputs.map(\.event)
        #expect(!events.contains { if case .mailDelivered = $0 { true } else { false } })
        #expect(MailQueueFixtures.cancelledIds(in: events).count == 2)
    }
}
