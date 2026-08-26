import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``ToolDetachment``: which layer a tool is mounted in — by the
/// mount it declares for itself, or by the site's configuration — and the
/// binding-only path for a non-`String`-output tool.
@Suite("ToolDetachment: mount a tool in the layer it declares")
struct ToolDetachmentTests {
    private typealias Fixtures = MountFixtures

    /// How many ``MountFixtures/shortInterval`` windows a declared
    /// run-to-completion call is held for: past the site's timeout, so only
    /// the declaration can explain a call that is neither backgrounded nor
    /// timed out.
    private static let declaredMountHoldWindows: Double = 3

    /// Mounts `tool` through the one session-mount composition every
    /// session tool-instancing site shares.
    private static func sessionMounted(
        _ tool: any Tool, sessionID: ULID, mailbox: SessionMailbox, sink: Fixtures.RecordingSink
    ) -> any Tool {
        ToolDetachment.sessionMounted(
            tool: tool, sessionID: sessionID, mailbox: mailbox, sink: sink, cappedToTokenLimit: nil
        )
    }

    // MARK: - The String-output path

    @Test("wrapping discovers a String-output tool from any Tool and mounts it in the background layer when the site says so")
    func factoryWrapsStringOutputTool() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: Fixtures.GatedTool(gate: gate),
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: sink,
            configuration: DetachConfiguration(mode: .background)
        )

        let mounted = try #require(wrapped as? BackgroundTool<MountArguments>)
        #expect(mounted.timeout == DetachConfiguration.defaultTimeoutSeconds)
        let rendered = try await mounted.call(arguments: MountArguments(value: "factory"))
        let envelope = try Fixtures.decodeEnvelope(rendered)
        #expect(envelope.pending)

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: mailbox)
        #expect(terminal.detail == "gated: factory")
    }

    @Test("wrapping inheriting a ToolContext tracks the run in that context's own mailbox, on its session plane")
    func factoryInheritsMailboxAndSessionIdentity() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sessionID = ULID.generate()
        let sink = Fixtures.RecordingSink()
        let outer = ToolContext(
            stamping: Fixtures.GatedSessionIdentityTool(gate: gate),
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false }
        )
        let wrapped = ToolDetachment.wrapping(
            tool: Fixtures.GatedSessionIdentityTool(gate: gate),
            inheriting: outer,
            sink: sink,
            configuration: DetachConfiguration(mode: .background)
        )

        let mounted = try #require(wrapped as? BackgroundTool<MountArguments>)
        let rendered = try await mounted.call(arguments: MountArguments(value: "inherited"))
        let envelope = try Fixtures.decodeEnvelope(rendered)

        // The run was tracked in the mailbox the inherited context carries —
        // a mailbox this call never named.
        let runs = await mailbox.backgroundRuns()
        #expect(runs.map(\.completionToken) == [envelope.completionToken])

        await gate.open()
        let terminal = try await Fixtures.settledTerminal(of: envelope.completionToken, in: mailbox)
        // The inner run ran on the inherited session plane.
        #expect(terminal.detail == sessionID.ulidString)
        #expect(terminal.outcome == .succeeded)
    }

    // MARK: - The non-String-output path

    @Test("wrapping wraps a non-String-output tool in the binding-only ContextBindingTool")
    func factoryBindsNonStringOutputTool() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: Fixtures.NonStringOutputTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            configuration: DetachConfiguration(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<MountArguments, NonStringToolOutput>)
        let output = try await binding.call(arguments: MountArguments(value: "silent"))

        // The wrapped tool's own output passes through unchanged, and a
        // silent run posts nothing at all.
        #expect(output.text == "ignored")
        #expect(await sink.events.isEmpty)
    }

    @Test("a non-String-output tool's ambient posts carry its own tool identity and a fresh per-call correlationID")
    func nonStringOutputToolAmbientPostsCarryPerCallIdentity() async throws {
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: AmbientNonStringOutputTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            configuration: DetachConfiguration(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let first = try await binding.call(arguments: AmbientToolArguments(value: "one"))
        let second = try await binding.call(arguments: AmbientToolArguments(value: "two"))

        let events = await sink.events
        #expect(events.map(\.detail) == ["one", "two"])
        #expect(events.map(\.tool) == ["ambient-non-string", "ambient-non-string"])
        #expect(events.map(\.op) == ["ambient-non-string", "ambient-non-string"])
        // Run scope, never session scope: each call minted its own token.
        #expect(events.map(\.correlationID) == [first.text, second.text])
        #expect(first.text != second.text)
        #expect(ULID(first.text) != nil)
    }

    @Test("wrapping inheriting a ToolContext binds a non-String-output tool on that context's session plane")
    func factoryInheritsAmbientContext() async throws {
        let sink = Fixtures.RecordingSink()
        let outer = ToolContext(
            stamping: AmbientNonStringOutputTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            completionToken: "outer-run",
            isCancelled: { false }
        )
        let wrapped = ToolDetachment.wrapping(
            tool: AmbientNonStringOutputTool(),
            inheriting: outer,
            sink: sink,
            configuration: DetachConfiguration(mode: .background)
        )

        let binding = try #require(wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let inner = try await binding.call(arguments: AmbientToolArguments(value: "inherited"))

        // The inner call is bound under its own identity, on a fresh
        // correlation of its own rather than the outer run's token.
        let events = await sink.events
        #expect(events.map(\.detail) == ["inherited"])
        #expect(events.map(\.tool) == ["ambient-non-string"])
        #expect(events.map(\.correlationID) == [inner.text])
        #expect(inner.text != outer.completionToken)
    }

    // MARK: - The mount a tool declares for itself

    @Test("a tool that declares nothing mounts run-to-completion under the stock timeout, and its slow call stays in band")
    func undeclaredToolMountsRunToCompletion() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let mounted = try #require(
            Self.sessionMounted(
                Fixtures.GatedTool(gate: gate), sessionID: ULID.generate(), mailbox: mailbox, sink: sink
            ) as? RunToCompletionTool<MountArguments>
        )

        #expect(mounted.timeout == DetachConfiguration.defaultTimeoutSeconds)

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

    @Test("a tool that declares background mounts in the background layer under its own declaration, and its call is handed back as a token at once")
    func declaredToolMountsBackground() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let mounted = try #require(
            Self.sessionMounted(
                Fixtures.DeclaredBackgroundTool(gate: gate), sessionID: ULID.generate(),
                mailbox: mailbox, sink: sink
            ) as? BackgroundTool<MountArguments>
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

    @Test("a tool's declared mount wins over the configuration the composition site passes, clock and all")
    func declaredMountOverridesTheSiteConfiguration() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: Fixtures.DeclaredRunToCompletionTool(gate: gate),
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: sink,
            configuration: DetachConfiguration(mode: .background, timeout: Fixtures.shortInterval)
        )

        let mounted = try #require(wrapped as? RunToCompletionTool<MountArguments>)
        #expect(mounted.timeout == nil)

        let calling = Task {
            try await mounted.call(arguments: MountArguments(value: "catalogue"))
        }
        // Held past the site's timeout: a call that took the site's mount
        // would have been backgrounded at once, and then timed out.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.declaredMountHoldWindows))
        #expect(await mailbox.backgroundRuns().isEmpty)
        await gate.open()

        let rendered = try await calling.value
        #expect(rendered == "declared: catalogue")
        #expect(await mailbox.backgroundRuns().isEmpty)
        // A slow call is not a failed call: the run settles silently.
        #expect(await sink.events.isEmpty)
    }

    @Test("two tools on one session hold their own modes: one blocks in band while the other is handed back as a token")
    func oneSessionMountsBothModes() async throws {
        let sessionID = ULID.generate()
        let mailbox = SessionMailbox()
        let sink = Fixtures.RecordingSink()
        let blockingGate = RunLatch()
        let backgroundingGate = RunLatch()
        // Both tools take the one session-mount composition, under one
        // session identity, one mailbox, and one sink.
        let blocking = try #require(
            Self.sessionMounted(
                Fixtures.DeclaredRunToCompletionTool(gate: blockingGate), sessionID: sessionID,
                mailbox: mailbox, sink: sink
            ) as? RunToCompletionTool<MountArguments>
        )
        let backgrounding = try #require(
            Self.sessionMounted(
                Fixtures.DeclaredBackgroundTool(gate: backgroundingGate), sessionID: sessionID,
                mailbox: mailbox, sink: sink
            ) as? BackgroundTool<MountArguments>
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
}
