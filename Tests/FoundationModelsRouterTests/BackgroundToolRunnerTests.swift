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

    // MARK: - The wait before the handle

    @Test("a run that settles inside its tool's grace answers with the result in the same envelope, and the mailbox still reports that result")
    func runSettlingInsideTheGraceAnswersInline() async throws {
        let gate = RunLatch()
        // Already open, so the body returns as soon as it starts and the
        // grace never has to elapse.
        await gate.open()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "now"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.outcome == OperationOutcome.succeeded.rawValue)
        #expect(envelope.detail == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(
            envelope.next
                == Fixtures.InlineGraceTool.resultInstruction(forCompletionToken: envelope.completionToken)
        )

        // The run settled by itself, so the mailbox holds the same result for
        // a model that calls wait on the token anyway.
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "now"))
        #expect(terminal.outcome == .succeeded)

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
    }

    @Test("a tool that declares a grace and no sentence of its own carries the default settled sentence")
    func settledEnvelopeTakesTheDefaultSentence() async throws {
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.DefaultSentenceGraceTool(grace: Fixtures.generousInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "now"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.detail == Fixtures.DefaultSentenceGraceTool.output(for: "now"))
        #expect(
            envelope.next
                == PendingRunEnvelope.defaultResultInstruction(forCompletionToken: envelope.completionToken)
        )
    }

    @Test("a run still going when the grace elapses answers with the pending envelope, and settles behind it as before")
    func runStillGoingWhenTheGraceElapsesAnswersPending() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.shortInterval)
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "later"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(envelope.detail == nil)
        #expect(envelope.outcome == nil)
        #expect(
            envelope.next
                == PendingRunEnvelope.defaultCollectInstruction(forCompletionToken: envelope.completionToken)
        )

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == Fixtures.InlineGraceTool.output(for: "later"))
    }

    @Test("an inline result leaves nothing staged for a later prompt, and a pending run still stages its progress")
    func inlineResultWithdrawsWhatTheRunStaged() async throws {
        let mailbox = SessionMailbox()
        let outbox = SessionOutbox()
        let gate = RunLatch()
        await gate.open()
        let inline = BackgroundToolRunner(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval),
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: outbox,
            timeout: ToolMount.defaultTimeoutSeconds
        )

        let rendered = try await inline.call(arguments: MountArguments(value: "inline"))

        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        let afterInline = await outbox.pending()
        #expect(afterInline.events.isEmpty)

        // The same outbox still stages a run whose result the model has not
        // been given, so the withdrawal is the settled case alone.
        let held = RunLatch()
        let pendingRun = BackgroundToolRunner(
            wrapping: Fixtures.GatedTool(gate: held),
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: outbox,
            timeout: ToolMount.defaultTimeoutSeconds
        )

        let pendingRendered = try await pendingRun.call(arguments: MountArguments(value: "held"))

        let pendingEnvelope = try Fixtures.decodeEnvelope(pendingRendered)
        #expect(pendingEnvelope.pending)
        let afterPending = await outbox.pending()
        #expect(afterPending.events.count == 1)
        #expect(afterPending.events.first?.event.correlationID == pendingEnvelope.completionToken)

        await held.open()
        _ = try await Fixtures.settledTerminal(of: pendingEnvelope.completionToken, in: mailbox)
    }

    @Test("the capping layer cuts a settled envelope's detail and leaves its completionToken and sentence whole")
    func tokenCappingCutsOnlyTheDetailOfASettledEnvelope() async throws {
        let gate = RunLatch()
        await gate.open()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval)
        )
        let capping = TokenCappingTool(wrapped: harness.mounted, limit: Self.tinyTokenLimit)

        let rendered = try await capping.call(arguments: MountArguments(value: "capped"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.detail != Fixtures.InlineGraceTool.output(for: "capped"))
        #expect(
            envelope.detail
                == ToolOutputCapping.capped(
                    text: Fixtures.InlineGraceTool.output(for: "capped"),
                    toTokenLimit: Self.tinyTokenLimit
                )
        )
        #expect(
            envelope.next
                == Fixtures.InlineGraceTool.resultInstruction(forCompletionToken: envelope.completionToken)
        )
        #expect(ULID(ulidString: envelope.completionToken) != nil)
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

    // MARK: - Attachments

    @Test("attachments made after the run is handed back still reach that run's settlement, in call order")
    func lateAttachmentsReachTheSettlement() async throws {
        let gate = RunLatch()
        let sink = Fixtures.RecordingSink()
        let arguments = MountArguments(value: "late")
        let run = Fixtures.toolRun(
            wrapping: Fixtures.GatedAttachingTool(gate: gate), arguments: arguments, sink: sink
        )

        await run.open()
        // The body runs behind the hand-back, the way `BackgroundToolRunner`
        // runs it: this task is the run, and control returns at once.
        let settling = Task { await run.execute(arguments: arguments) }
        // The second record lands only after the gate opens, so it is made
        // after the hand-back.
        await gate.open()
        let settlement = await settling.value

        #expect(settlement.attachments == Fixtures.attachmentsInCallOrder)
        #expect(try settlement.result.get() == "attached late: late")
    }

    @Test("attachments never reach the envelope, the terminal, or any event of a background call")
    func attachmentsStayOutOfTheModelFacingOutput() async throws {
        let gate = RunLatch()
        let harness = Fixtures.backgroundHarness(wrapping: Fixtures.GatedAttachingTool(gate: gate))

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!Fixtures.isAttachmentMentioned(in: rendered))

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == "attached late: x")

        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(!events.contains { Fixtures.isAttachmentMentioned(in: $0.detail) })
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
