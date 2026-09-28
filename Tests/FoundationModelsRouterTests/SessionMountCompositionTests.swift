import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the session mount of the router,
/// `ToolMounting.makeSessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:tokenCounter:tracer:)`:
/// the Extras mount layer, the capping layer of the router
/// (`TokenCappingTool`) over it, and the failure-delivery decorator outermost.
/// It also exercises the capping layer over a background envelope, and the
/// withdrawal of staged events from the ``SessionOutbox`` of the router.
///
/// The tests of the Extras mount layer alone moved to FoundationModelsExtras
/// with the tool hosting (its `ToolMountingTests`, `ToolFailureDeliveryTests`
/// and `BackgroundToolRunnerTests`). These tests stay here because they drive
/// router types.
@Suite("Session mount composition: the Extras mount, the capping layer, and failure delivery")
struct SessionMountCompositionTests {
    private typealias Fixtures = MountFixtures

    /// How long, in seconds, the tool with no stated timeout runs with no
    /// progress. Task ^50c8zer names this length.
    private static let quietRunSeconds: TimeInterval = 3

    /// The step every marker-tool call of this suite names.
    private static let step = "ONE"

    /// The arguments every marker-tool call of this suite sends.
    private static let arguments = AmbientToolArguments(value: step)

    /// The text the model reads for a call of a marker tool that failed on
    /// ``step``.
    private static let failureText = String(describing: ThrowingMarkerTool.CallFailure(step: step))

    /// A tool-output token cap, so the session mount adds its capping layer.
    /// Only its presence matters, not its size.
    private static let cappedToolOutputLimit = 256

    /// A token limit far below the character count of any rendered envelope,
    /// so only the envelope exemption can let one through the capping layer.
    private static let tinyTokenLimit = 1

    /// Mounts `tool` through the one session-mount composition every
    /// session tool-instancing site shares, and returns the mount layer
    /// beneath its outermost failure-delivery decorator — the layer this
    /// suite reads.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - sessionID: The session of each call.
    ///   - mailbox: The run plane of the session.
    ///   - sink: The sink of the events of each call.
    /// - Returns: The mount layer beneath the failure-delivery decorator.
    private static func makeSessionMounted(
        _ tool: any Tool, sessionID: ULID, mailbox: RunPlane, sink: Fixtures.RecordingSink
    ) -> any Tool {
        ToolFailureDelivery.throwingTool(
            of: ToolMounting.makeSessionMounted(
                tool: tool, sessionID: sessionID, mailbox: mailbox, sink: sink, cappedToTokenLimit: nil,
                tokenCounter: characterTokenCounter
            ))
    }

    // MARK: - The mount a tool declares for itself

    @Test("a tool that declares nothing mounts run-to-completion with no timeout, and its slow call stays in band")
    func undeclaredToolMountsRunToCompletion() async throws {
        let gate = RunLatch()
        let mailbox = RunPlane()
        let sink = Fixtures.RecordingSink()
        let mounted = try #require(
            Self.makeSessionMounted(
                Fixtures.GatedTool(gate: gate), sessionID: ULID.generate(), mailbox: mailbox, sink: sink
            ) as? RunToCompletionRunner<MountArguments>
        )

        #expect(mounted.timeout == nil)

        let calling = Task {
            try await mounted.call(arguments: MountArguments(value: "edit"))
        }
        try await Task.sleep(for: .seconds(Fixtures.shortInterval))
        // No token was handed out: the call is still in band.
        #expect(await mailbox.backgroundRuns().isEmpty)
        await gate.open()

        let rendered = try await calling.value
        #expect(rendered == "gated: edit")
        #expect(await mailbox.backgroundRuns().isEmpty)
    }

    @Test("a tool with no stated timeout that runs with no progress completes")
    func unstatedTimeoutLetsAQuietRunComplete() async throws {
        let mounted = Self.makeSessionMounted(
            Fixtures.QuietTool(duration: Self.quietRunSeconds), sessionID: ULID.generate(),
            mailbox: RunPlane(), sink: Fixtures.RecordingSink()
        )
        let quiet = try #require(mounted as? RunToCompletionRunner<MountArguments>)

        let rendered = try await quiet.call(arguments: MountArguments(value: "slow"))

        #expect(rendered == "quiet: slow")
    }

    @Test("a tool that declares background mounts in the background layer under its own declaration, and its call is handed back as a token at once")
    func declaredToolMountsBackground() async throws {
        let gate = RunLatch()
        let mailbox = RunPlane()
        let sink = Fixtures.RecordingSink()
        let mounted = try #require(
            Self.makeSessionMounted(
                Fixtures.DeclaredBackgroundToolRunner(gate: gate), sessionID: ULID.generate(),
                mailbox: mailbox, sink: sink
            ) as? BackgroundToolRunner<MountArguments>
        )

        #expect(mounted.timeout == nil)

        let rendered = try await mounted.call(arguments: MountArguments(value: "tests"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(await mailbox.backgroundRuns().map(\.tool) == ["declared_background_tool"])

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: mailbox)
        #expect(terminal.detail == "background: tests")
    }

    @Test("two tools on one session hold their own modes: one blocks in band while the other is handed back as a token")
    func oneSessionMountsBothModes() async throws {
        let sessionID = ULID.generate()
        let mailbox = RunPlane()
        let sink = Fixtures.RecordingSink()
        let blockingGate = RunLatch()
        let backgroundingGate = RunLatch()
        // Both tools take the one session-mount composition, under one
        // session identity, one run plane, and one sink.
        let blocking = try #require(
            Self.makeSessionMounted(
                Fixtures.DeclaredRunToCompletionRunner(gate: blockingGate), sessionID: sessionID,
                mailbox: mailbox, sink: sink
            ) as? RunToCompletionRunner<MountArguments>
        )
        let backgrounding = try #require(
            Self.makeSessionMounted(
                Fixtures.DeclaredBackgroundToolRunner(gate: backgroundingGate), sessionID: sessionID,
                mailbox: mailbox, sink: sink
            ) as? BackgroundToolRunner<MountArguments>
        )

        // The tool that declares background is handed back as a token.
        let rendered = try await backgrounding.call(arguments: MountArguments(value: "snippet"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)

        // On that same session the run-to-completion tool blocks instead.
        let discovering = Task {
            try await blocking.call(arguments: MountArguments(value: "catalogue"))
        }
        try await Task.sleep(for: .seconds(Fixtures.shortInterval))

        // One run is tracked, and it is the background tool's.
        let runs = await mailbox.backgroundRuns()
        #expect(runs.count == 1)
        #expect(runs.first?.tool == "declared_background_tool")

        await blockingGate.open()
        let catalogue = try await discovering.value
        #expect(catalogue == "declared: catalogue")

        await backgroundingGate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: mailbox)
        #expect(terminal.detail == "background: snippet")
    }

    // MARK: - The failure-delivery decorator outermost

    @Test(
        "the session mount puts the decorator outermost, over the capping layer",
        arguments: [nil, cappedToolOutputLimit])
    func sessionMountPutsTheDecoratorOutermost(tokenLimit: Int?) throws {
        let mounted = ToolMounting.makeSessionMounted(
            tool: ThrowingMarkerTool(), sessionID: .generate(), mailbox: RunPlane(),
            sink: DiscardingOperationEventSink(), cappedToTokenLimit: tokenLimit,
            tokenCounter: characterTokenCounter)

        #expect(mounted is FailureDeliveringTextTool<AmbientToolArguments>)
        let beneath = ToolFailureDelivery.throwingTool(of: mounted)
        let expectsCapping = tokenLimit != nil
        #expect((beneath is TokenCappingTool<AmbientToolArguments>) == expectsCapping)
    }

    @Test("a failed call through the whole session mount is a tool result")
    func sessionMountedFailureIsAToolResult() async throws {
        let mounted = ToolMounting.makeSessionMounted(
            tool: ThrowingMarkerTool(), sessionID: .generate(), mailbox: RunPlane(),
            sink: DiscardingOperationEventSink(), cappedToTokenLimit: nil,
            tokenCounter: characterTokenCounter)
        let tool = try #require(mounted as? FailureDeliveringTextTool<AmbientToolArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == Self.failureText)
    }

    // MARK: - The capping layer over a background envelope

    @Test("TokenCappingTool passes a rendered envelope through uncapped, with the default sentence and with a tool's own")
    func tokenCappingPassesRenderedEnvelopesThrough() async throws {
        let gate = RunLatch()
        let harnesses = [
            Fixtures.backgroundHarness(wrapping: Fixtures.GatedTool(gate: gate)),
            Fixtures.backgroundHarness(wrapping: Fixtures.CollectSentenceTool(gate: gate), timeout: nil),
        ]

        var completionTokens: [String] = []
        for harness in harnesses {
            let capping = TokenCappingTool(wrapped: harness.mounted, limit: Self.tinyTokenLimit, counter: characterTokenCounter)

            let rendered = try await capping.call(arguments: MountArguments(value: "capped"))

            // The cap would have bitten: the envelope is not short enough to
            // pass on size alone.
            #expect(
                ToolOutputCapping.capped(text: rendered, toTokenLimit: Self.tinyTokenLimit, counter: characterTokenCounter)
                    != rendered)
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

    @Test("the capping layer cuts a settled envelope's detail and leaves its completionToken and sentence whole")
    func tokenCappingCutsOnlyTheDetailOfASettledEnvelope() async throws {
        let gate = RunLatch()
        await gate.open()
        let harness = Fixtures.backgroundHarness(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval)
        )
        let capping = TokenCappingTool(wrapped: harness.mounted, limit: Self.tinyTokenLimit, counter: characterTokenCounter)

        let rendered = try await capping.call(arguments: MountArguments(value: "capped"))

        #expect(PendingRunEnvelope.isRendered(text: rendered))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(!envelope.pending)
        #expect(envelope.detail != Fixtures.InlineGraceTool.output(for: "capped"))
        #expect(
            envelope.detail
                == ToolOutputCapping.capped(
                    text: Fixtures.InlineGraceTool.output(for: "capped"),
                    toTokenLimit: Self.tinyTokenLimit,
                    counter: characterTokenCounter
                )
        )
        #expect(
            envelope.next
                == Fixtures.InlineGraceTool.resultInstruction(forCompletionToken: envelope.completionToken)
        )
        #expect(ULID(ulidString: envelope.completionToken) != nil)
    }

    // MARK: - The staged events of the session outbox

    @Test("an inline result leaves nothing staged for a later prompt, and a pending run still stages its progress")
    func inlineResultWithdrawsWhatTheRunStaged() async throws {
        let mailbox = RunPlane()
        let outbox = SessionOutbox()
        let site = MountSite(sessionID: ULID.generate(), runPlane: mailbox, sink: outbox)
        let gate = RunLatch()
        await gate.open()
        let inline = BackgroundToolRunner(
            wrapping: Fixtures.InlineGraceTool(gate: gate, grace: Fixtures.generousInterval),
            site: site,
            timeout: nil
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
            site: site,
            timeout: nil
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
}
