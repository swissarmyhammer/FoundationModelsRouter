import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``BackgroundToolRunner``: the envelope on every call, the mailbox
/// entry, the event sequence, the timeout on a background run, the
/// canceler, the run-plane snapshot, and exactly one `.completed` across
/// natural settle, cancel, and timeout.
@Suite("BackgroundToolRunner: start the body, return the handle at once")
struct BackgroundToolRunnerTests {
    private typealias Fixtures = MountFixtures

    /// How many heartbeats a beating background run posts after it is handed back.
    private static let beatingRunBeats = 20

    /// How many heartbeats the run-plane snapshot test's tool posts.
    private static let snapshotRunBeats = 40

    /// The pause between two heartbeats.
    private static let heartbeatInterval: TimeInterval = 0.05

    /// A token limit far below any rendered envelope's estimated size, so
    /// only the envelope exemption can let one through the capping layer.
    private static let tinyTokenLimit = 1

    // MARK: - The handle on every call

    @Test("a background tool whose body completes instantly still returns a PendingRunEnvelope: the run is tracked before the body runs")
    func instantBodyStillReturnsEnvelope() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.TrackedAtStartTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "instant"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == Fixtures.TrackedAtStartTool.trackedOutput)
        #expect(terminal.outcome == .succeeded)
        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    @Test("a background call is handed back at once: pending envelope, mailbox entry, synthesized progress, one terminal upstream")
    func backgroundCallIsHandedBackAtOnce() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.GatedTool(gate: gate))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "slow"))

        // The pending envelope: pending flag plus a ULID completion token.
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(ULID(ulidString: envelope.completionToken) != nil)

        // The mailbox holds the run under that token, kind swiftTask.
        let status = await harness.mailbox.backgroundRuns()
        #expect(status.count == 1)
        #expect(status.first?.completionToken == envelope.completionToken)
        #expect(status.first?.kind == .swiftTask)
        #expect(status.first?.tool == "gated_tool")

        // One synthesized progress at hand-back, on the run's correlation.
        let eventsAtHandBack = await harness.sink.events
        #expect(eventsAtHandBack.count == 1)
        #expect(eventsAtHandBack.first?.kind == .progress)
        #expect(eventsAtHandBack.first?.correlationID == envelope.completionToken)
        #expect(eventsAtHandBack.first?.tool == "gated_tool")

        // Settle the run; the terminal event carries the rendered output in
        // detail, the token as correlationID, and outcome succeeded — and it
        // went upstream even though wait() collected it here.
        await gate.open()
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.kind == .completed)
        #expect(terminal.detail == "gated: slow")
        #expect(terminal.correlationID == envelope.completionToken)
        #expect(terminal.outcome == .succeeded)

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.last?.detail == "gated: slow")
        #expect(events.last?.outcome == .succeeded)
        #expect(events.last?.correlationID == envelope.completionToken)
    }

    @Test("a tool that supplies its own collect sentence gets that sentence rendered as the envelope's next field")
    func toolSuppliedCollectInstructionIsRendered() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.CollectSentenceTool(gate: gate), timeout: nil
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "own sentence"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(
            envelope.next
                == Fixtures.CollectSentenceTool.collectInstruction(forCompletionToken: envelope.completionToken)
        )
        #expect(
            rendered
                == PendingRunEnvelope(completionToken: envelope.completionToken, next: envelope.next).rendered
        )

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == "collected: own sentence")
    }

    @Test("TokenCappingTool passes a rendered envelope through uncapped, with the default sentence and with a tool's own")
    func tokenCappingPassesRenderedEnvelopesThrough() async throws {
        let gate = RunLatch()
        let harnesses = [
            Fixtures.backgroundHarness(wrapping: Fixtures.GatedTool(gate: gate)),
            Fixtures.backgroundHarness(wrapping: Fixtures.CollectSentenceTool(gate: gate), timeout: nil),
        ]

        var completionTokens: [String] = []
        for harness in harnesses {
            let capping = TokenCappingTool(wrapped: harness.mounted, limit: Self.tinyTokenLimit)

            let rendered = try await capping.call(arguments: MountArguments(value: "capped"))

            // The cap would have bitten: the envelope is not short enough to
            // pass on size alone.
            #expect(ToolOutputCapping.capped(text: rendered, toTokenLimit: Self.tinyTokenLimit) != rendered)
            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let envelope = try Fixtures.decodeEnvelope(rendered)
            #expect(
                rendered
                    == PendingRunEnvelope(completionToken: envelope.completionToken, next: envelope.next).rendered
            )
            completionTokens.append(envelope.completionToken)
        }

        await gate.open()
        for (harness, completionToken) in zip(harnesses, completionTokens) {
            _ = try await Fixtures.settledTerminal(of: completionToken, in: harness.mailbox)
        }
    }

    // MARK: - Exactly one terminal on every path

    @Test("a background run that beats on after it is handed back settles once, with exactly one synthesized terminal")
    func beatingBackgroundRunSettlesOnce() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.beatingRunBeats, interval: Self.heartbeatInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)

        // The run posts its own progress after it is handed back, and it
        // still gets exactly one synthesized terminal at settlement.
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "heartbeat done")

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.contains { $0.kind == .progress && $0.detail.hasPrefix("beat ") })
    }

    @Test("timeout expiry on a background run settles it with outcome timedOut and exactly one terminal")
    func timeoutExpiryOnBackgroundRun() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.SleepingTool(), timeout: Fixtures.shortInterval
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .timedOut)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    @Test("cancelling a background run settles it with outcome cancelled and exactly one terminal")
    func cancellingBackgroundRunYieldsOneCancelledTerminal() async throws {
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.SleepingTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let cancelResult = await harness.mailbox.cancel(completionToken: envelope.completionToken)
        #expect(cancelResult == .reported(.cancelled))

        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .cancelled)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .cancelled)
    }

    @Test("a cancelled run's cooperative flag reaches the tool through ToolContext.isCancelled")
    func cancellationFlagReachesTool() async throws {
        let witness = Fixtures.CancellationWitness()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.CancellationFlagPollingTool(witness: witness)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        let cancelResult = await harness.mailbox.cancel(completionToken: envelope.completionToken)
        #expect(cancelResult == .reported(.cancelled))

        // The tool never observes structured cancellation — only the flag —
        // and chooses to return normally once it flips: an honest success.
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == "observed cancellation")
        #expect(terminal.outcome == .succeeded)
        #expect(await witness.observed)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    // MARK: - The run-plane snapshot

    @Test("background-run progress feeds the mailbox's run-plane snapshot")
    func backgroundRunProgressFeedsStatus() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.snapshotRunBeats, interval: Self.heartbeatInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        // Poll (bounded) until a beat lands in the background run's status row.
        let observedDetail = try await Fixtures.poll {
            await harness.mailbox.backgroundRuns().first?.latestProgressDetail
        }
        #expect(observedDetail?.hasPrefix("beat ") == true)

        _ = try await Fixtures.settledTerminal(of: envelope.completionToken, in: harness.mailbox)
    }
}
