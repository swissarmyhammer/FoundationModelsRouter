import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RunToCompletionRunner``: the in-band result, the per-call
/// timeout through ``BackgroundTool``, the timeout that
/// progress resets and an elicitation suspends, the terminal-scoped
/// synthesis matrix, and exactly one `.completed` on the throw and timeout
/// paths.
@Suite("RunToCompletionRunner: run the body, return its value")
struct RunToCompletionRunnerTests {
    private typealias Fixtures = MountFixtures

    /// How many heartbeats the progress-resets-timeout tool posts.
    private static let heartbeatCount = 8

    /// The pause between two heartbeats, well inside ``heartbeatTimeout``.
    private static let heartbeatInterval: TimeInterval = 0.1

    /// The timeout the heartbeats keep resetting; the run's whole length
    /// (``heartbeatCount`` × ``heartbeatInterval``) is past it.
    private static let heartbeatTimeout: TimeInterval = 0.5

    /// How many ``MountFixtures/shortInterval`` windows a clockless call is
    /// held for: more than one, so the mount's having no clock is the only
    /// reason it still returns.
    private static let clocklessHoldWindows: Double = 3

    /// How many timeout windows an answer is held for, to prove a pending
    /// elicitation suspends the timeout the whole time.
    private static let elicitationHoldWindows: Double = 3

    // MARK: - The in-band path

    @Test("a fast tool returns its rendered output in band and posts no events at all")
    func fastToolIsSilent() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.FastTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "fast: x")
        #expect(await harness.sink.events.isEmpty)
        #expect(await harness.mailbox.backgroundRuns().isEmpty)
    }

    // MARK: - The per-call timeout

    @Test("a per-call timeout overrides the mount's timeout")
    func perCallTimeoutOverridesMount() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.PerCallTimeoutTool(timeoutSeconds: Fixtures.shortInterval),
            timeout: Fixtures.generousInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("a nil per-call timeout falls back to the mount's timeout")
    func nilPerCallTimeoutFallsBackToMount() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.NilTimeoutTool(), timeout: Fixtures.shortInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The timeout

    @Test("progress resets the timeout: a tool that beats faster than the timeout survives past it")
    func progressResetsTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.HeartbeatTool(beats: Self.heartbeatCount, interval: Self.heartbeatInterval),
            timeout: Self.heartbeatTimeout
        )

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "heartbeat done")
        let events = await harness.sink.events
        #expect(events.last?.kind == .completed)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("timeout expiry cancels the work and throws the one named error, with outcome timedOut")
    func timeoutExpiryThrowsNamedError() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.SleepingTool(), timeout: Fixtures.shortInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("timeout expiry also raises the cooperative flag the tool observes")
    func timeoutSetsCancellationFlag() async throws {
        let witness = Fixtures.CancellationWitness()
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.CancellationFlagPollingTool(witness: witness),
            timeout: Fixtures.shortInterval
        )

        await #expect(throws: ToolMountError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        // The race resolved as timedOut; the tool keeps polling until the
        // flag the timeout raised reaches it.
        let observed = try await Fixtures.poll { await witness.observed ? true : nil }
        #expect(observed == true)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - Terminal-scoped synthesis matrix

    @Test("progress-only run still yields exactly one synthesized terminal")
    func progressOnlyRunGetsSynthesizedTerminal() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ProgressOnceTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "progressed: x")
        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.last?.outcome == .succeeded)
        #expect(events.last?.detail == "progressed: x")
    }

    @Test("a tool that posts its own terminal event gets no duplicate")
    func ownTerminalToolGetsNoDuplicate() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.OwnTerminalTool())

        let rendered = try await harness.mounted.call(arguments: MountArguments(value: "x"))

        #expect(rendered == "own-terminal: x")
        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.detail == "my own terminal")
    }

    @Test("a tool that throws rethrows in band and yields exactly one terminal with outcome failed")
    func throwingToolYieldsOneFailedTerminal() async throws {
        let harness = Fixtures.runToCompletionHarness(wrapping: Fixtures.ThrowingTool())

        await #expect(throws: Fixtures.FixtureError.self) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }

    // MARK: - Elicitation suspends the timeout

    @Test("a pending elicitation suspends the timeout for as long as it is unanswered")
    func pendingElicitationSuspendsTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.ElicitOnceTool(), timeout: Fixtures.shortInterval
        )

        let calling = AnswerDrivenRun(waitingFor: "the tool call blocked on its elicitation") {
            try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }
        let elicitationId = try await Fixtures.firstPendingElicitationId(in: harness.mailbox)

        // Hold the answer across several full timeout windows: the pending
        // elicitation must suspend the timeout the whole time.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.elicitationHoldWindows))
        await harness.mailbox.respond(
            elicitationId: elicitationId, .accept(content: ["ok": .boolean(true)])
        )

        let rendered = try await calling.deliveredAnswer()
        #expect(rendered == "answered: accept")

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("an answered elicitation restores the timeout with a fresh window: a run that then stalls still times out")
    func elicitationResolutionRestoresTimeout() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.ElicitThenStallTool(), timeout: Fixtures.shortInterval
        )

        let calling = AnswerDrivenRun(waitingFor: "the tool call blocked on its elicitation") {
            try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }
        let elicitationId = try await Fixtures.firstPendingElicitationId(in: harness.mailbox)
        await harness.mailbox.respond(elicitationId: elicitationId, .decline)

        await #expect(throws: ToolMountError.self) {
            _ = try await calling.deliveredAnswer()
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The clockless mount

    @Test("the run-to-completion mount carries no timeout at all")
    func synchronousUnboundedCarriesNoTimeout() {
        #expect(ToolMount.synchronousUnbounded.mode == .runToCompletion)
        #expect(ToolMount.synchronousUnbounded.timeout == nil)
    }

    @Test("the stock timeout stays a plain TimeInterval, and the native session mount runs to completion under it")
    func stockTimeoutStaysNonOptional() {
        // The binding itself is the assertion about the type: a
        // `TimeInterval?` does not compile here.
        let stockTimeout: TimeInterval = ToolMount.defaultTimeoutSeconds

        #expect(
            ToolMount.synchronous
                == ToolMount(mode: .runToCompletion, timeout: stockTimeout)
        )
    }

    @Test("under no timeout a call blocks until the tool finishes, never backgrounds, and reports no timeout")
    func clocklessCallBlocksUntilTheToolFinishes() async throws {
        let gate = RunLatch()
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.GatedTool(gate: gate), timeout: nil
        )

        let calling = Task {
            try await harness.mounted.call(arguments: MountArguments(value: "discovery"))
        }
        // Hold the tool past the window a timeout would have killed it in.
        try await Task.sleep(for: .seconds(Fixtures.shortInterval * Self.clocklessHoldWindows))
        #expect(await harness.mailbox.backgroundRuns().isEmpty)
        await gate.open()

        let rendered = try await calling.value
        #expect(rendered == "gated: discovery")
        #expect(await harness.mailbox.backgroundRuns().isEmpty)
        // A slow call is not a failed call: the run settles silently.
        #expect(await harness.sink.events.isEmpty)
    }

    @Test("under no timeout only the tool's own error reaches the model")
    func clocklessCallReportsOnlyRealErrors() async throws {
        let harness = Fixtures.runToCompletionHarness(
            wrapping: Fixtures.ThrowingTool(), timeout: nil
        )

        await #expect(throws: Fixtures.FixtureError()) {
            _ = try await harness.mounted.call(arguments: MountArguments(value: "x"))
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }
}
