import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises the ``DetachingTool`` engine (task ^vvg7ztt): the inline fast
/// path, the detachment slow path (pending envelope, mailbox entry, event
/// sequence), zero-wait detach, per-call clocks through
/// ``DetachmentParameterProviding``, the two-clocks matrix (progress resets
/// `timeout`, never `waitSeconds`), the terminal-scoped synthesis matrix
/// (no events / progress-only / own-terminal), exactly-one-`.completed`
/// across the throw, cancel, and timeout paths, and detachment-off mode.
@Suite("DetachingTool: the two-clocks detachment engine")
struct DetachingToolTests {
    // MARK: - Interval fixtures

    /// A wait/timeout interval short enough to keep the suite fast but long
    /// enough that an in-window fixture never spuriously elapses it.
    private static let shortInterval: TimeInterval = 0.2

    /// A deadline a test treats as "never elapses within this test".
    private static let generousInterval: TimeInterval = 30

    /// The ceiling on any await a test performs against the mailbox.
    private static let settlementDeadline: TimeInterval = 30

    // MARK: - Argument fixtures

    @Generable
    struct DetachingArguments {
        let value: String
    }

    @Generable
    struct ClockedArguments {
        let value: String
        let waitSeconds: Double
    }

    // MARK: - Sink fixtures

    /// A sink that records every posted event, in order.
    private actor RecordingSink: OperationEventSink {
        private(set) var events: [OperationEvent] = []

        func post(event: OperationEvent) {
            events.append(event)
        }
    }

    // MARK: - Tool fixtures

    /// Returns immediately — the inline fast path's subject.
    private struct FastTool: Tool {
        let name = "fast_tool"
        let description = "returns immediately"

        func call(arguments: DetachingArguments) async throws -> String {
            "fast: \(arguments.value)"
        }
    }

    /// Blocks on a ``RunLatch`` until the test opens it — the detachment slow
    /// path's subject.
    private struct GatedTool: Tool {
        let name = "gated_tool"
        let description = "blocks until its gate opens"
        let gate: RunLatch

        func call(arguments: DetachingArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    /// The error ``ThrowingTool`` throws.
    private struct FixtureError: Error, Equatable {}

    /// Throws immediately — the tool-throws path's subject.
    private struct ThrowingTool: Tool {
        let name = "throwing_tool"
        let description = "throws immediately"

        func call(arguments: DetachingArguments) async throws -> String {
            throw FixtureError()
        }
    }

    /// Sleeps cooperatively until cancelled — the cancel and timeout paths'
    /// subject: `Task.sleep` throws `CancellationError` the moment the run's
    /// cancellation lands.
    private struct SleepingTool: Tool {
        let name = "sleeping_tool"
        let description = "sleeps until cancelled"

        func call(arguments: DetachingArguments) async throws -> String {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return "never returned"
        }
    }

    /// Posts one progress event of its own, then returns in-window — the
    /// progress-only row of the terminal-scoped synthesis matrix.
    private struct ProgressOnceTool: Tool {
        let name = "progress_once_tool"
        let description = "posts one progress event then returns"

        func call(arguments: DetachingArguments) async throws -> String {
            await ToolContext.current?.progress("halfway")
            return "progressed: \(arguments.value)"
        }
    }

    /// Posts its own terminal `.completed` event, then returns — the
    /// own-terminal row of the terminal-scoped synthesis matrix.
    private struct OwnTerminalTool: Tool {
        let name = "own_terminal_tool"
        let description = "posts its own terminal event then returns"

        func call(arguments: DetachingArguments) async throws -> String {
            await ToolContext.current?.post(
                OperationEvent(
                    tool: "", op: "", correlationID: "", kind: .completed,
                    detail: "my own terminal", outcome: .succeeded
                )
            )
            return "own-terminal: \(arguments.value)"
        }
    }

    /// Posts progress every `interval` seconds for `beats` beats, then
    /// returns — the two-clocks matrix's subject: each beat resets the
    /// per-call `timeout`, and none of them extends `waitSeconds`.
    private struct HeartbeatTool: Tool {
        let name = "heartbeat_tool"
        let description = "posts periodic progress then returns"
        let beats: Int
        let interval: TimeInterval

        func call(arguments: DetachingArguments) async throws -> String {
            for beat in 0..<beats {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await ToolContext.current?.progress("beat \(beat)")
            }
            return "heartbeat done"
        }
    }

    /// Blocks on a gate and conforms to ``DetachmentParameterProviding``,
    /// reading its per-call `waitSeconds` out of the opaque
    /// `GeneratedContent` — the per-call clock sourcing hook's subject.
    private struct PerCallClockTool: Tool, DetachmentParameterProviding {
        let name = "per_call_clock_tool"
        let description = "supplies waitSeconds from its own arguments"
        let gate: RunLatch

        func call(arguments: ClockedArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "clocked: \(arguments.value)"
        }

        func detachmentClocks(
            from arguments: GeneratedContent
        ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
            (try? arguments.value(Double.self, forProperty: "waitSeconds"), nil)
        }
    }

    /// Sleeps forever and conforms to ``DetachmentParameterProviding`` with a
    /// per-call `timeout` — the timeout half of the per-call hook.
    private struct PerCallTimeoutTool: Tool, DetachmentParameterProviding {
        let name = "per_call_timeout_tool"
        let description = "supplies a short per-call timeout"
        let timeoutSeconds: TimeInterval

        func call(arguments: DetachingArguments) async throws -> String {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return "never returned"
        }

        func detachmentClocks(
            from arguments: GeneratedContent
        ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
            (nil, timeoutSeconds)
        }
    }

    /// Blocks on a gate and conforms to ``DetachmentParameterProviding``
    /// returning all-nil clocks — the nil-falls-back-to-configuration case.
    private struct NilClockTool: Tool, DetachmentParameterProviding {
        let name = "nil_clock_tool"
        let description = "supplies no per-call clocks at all"
        let gate: RunLatch

        func call(arguments: DetachingArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "nil-clock: \(arguments.value)"
        }

        func detachmentClocks(
            from arguments: GeneratedContent
        ) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) {
            (nil, nil)
        }
    }

    /// Asks one question through `ToolContext.elicit` and returns the
    /// action it was answered with — the elicitation-suspends-timeout
    /// subject.
    private struct ElicitOnceTool: Tool {
        let name = "elicit_once_tool"
        let description = "asks one question then returns"

        func call(arguments: DetachingArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            let request = ElicitationRequest(
                message: "Proceed?",
                elicitationId: ULID.generate(),
                requestedSchema: ElicitationRequestedSchema(
                    properties: ["ok": .boolean(ElicitationBooleanSchema())]
                )
            )
            let response = try await context.elicit(request)
            return "answered: \(response.action.rawValue)"
        }
    }

    /// Elicits, then stalls forever — proves the answered elicitation
    /// restores the timeout with a fresh window rather than disabling it.
    private struct ElicitThenStallTool: Tool {
        let name = "elicit_then_stall_tool"
        let description = "asks one question then stalls forever"

        func call(arguments: DetachingArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            let request = ElicitationRequest(
                message: "Proceed?",
                elicitationId: ULID.generate(),
                requestedSchema: ElicitationRequestedSchema(
                    properties: ["ok": .boolean(ElicitationBooleanSchema())]
                )
            )
            _ = try await context.elicit(request)
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return "never returned"
        }
    }

    /// Records that a tool observed the run's cooperative cancellation
    /// flag.
    private actor CancellationWitness {
        private(set) var observed = false

        func mark() {
            observed = true
        }
    }

    /// Polls `ToolContext.isCancelled` — never structured task cancellation
    /// — and returns normally the moment the flag flips, marking the
    /// witness: the flag-reaches-the-tool subject for both the mailbox
    /// canceler and the timeout path.
    private struct CancellationFlagPollingTool: Tool {
        let name = "flag_polling_tool"
        let description = "returns when the ambient cancellation flag flips"
        let witness: CancellationWitness

        func call(arguments: DetachingArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            for _ in 0..<6_000 {
                if context.isCancelled {
                    await witness.mark()
                    return "observed cancellation"
                }
                // Deliberately swallow the cancellation error: this tool
                // cooperates through the flag alone.
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return "never cancelled"
        }
    }

    /// A silent non-`String`-output `Tool` — proves ``ToolDetachment/wrapping``
    /// wraps a tool whose rendered output the pending envelope could not
    /// replace in the binding-only ``ContextBindingTool``, which synthesizes
    /// no events for a silent run.
    private struct NonStringOutputTool: Tool {
        let name = "non_string_output_tool"
        let description = "returns a non-String PromptRepresentable"

        func call(arguments: DetachingArguments) async throws -> NonStringToolOutput {
            NonStringToolOutput(text: "ignored")
        }
    }

    /// Blocks on a ``RunLatch`` and then returns the ambient run's session
    /// identity — the subject of
    /// ``ToolDetachment/wrapping(tool:inheriting:sink:configuration:)``: the
    /// inner run must be bound on the session plane the inherited context
    /// names.
    private struct GatedSessionIdentityTool: Tool {
        let name = "gated_session_identity_tool"
        let description = "returns the ambient context's session identity once its gate opens"
        let gate: RunLatch

        func call(arguments: DetachingArguments) async throws -> String {
            await gate.waitUntilOpen()
            return ToolContext.current?.sessionID.ulidString ?? "unbound"
        }
    }

    // Note: there is deliberately no non-Sendable-Arguments fixture — a
    // `Tool` conformance with non-Sendable `Arguments` does not compile
    // (`Tool.call` is `@concurrent`), so the case ``ToolDetachment/wrapping``
    // would have to pass through is unrepresentable.

    // MARK: - Harness

    /// One test's wiring: the mailbox, sink, and wrapped engine.
    private struct Harness<Arguments: ConvertibleFromGeneratedContent & Sendable> {
        let mailbox: SessionMailbox
        let sink: RecordingSink
        let detaching: DetachingTool<Arguments>
    }

    /// Wraps `tool` in a ``DetachingTool`` over a fresh mailbox and
    /// recording sink.
    private static func makeHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        configuration: DetachConfiguration
    ) -> Harness<Arguments> {
        let mailbox = SessionMailbox()
        let sink = RecordingSink()
        let detaching = DetachingTool(
            wrapping: tool,
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: sink,
            configuration: configuration
        )
        return Harness(mailbox: mailbox, sink: sink, detaching: detaching)
    }

    /// The pending envelope's decoded shape.
    private struct DecodedEnvelope: Decodable {
        let pending: Bool
        let completionToken: String
        let next: String
    }

    /// Decodes the pending envelope out of a returned rendered output.
    private static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// Awaits the run's settlement through the mailbox and returns its
    /// terminal event.
    private static func settledTerminal(
        of completionToken: String, in mailbox: SessionMailbox
    ) async throws -> OperationEvent {
        let result = await mailbox.wait(
            completionToken: completionToken, seconds: settlementDeadline
        )
        guard case .settled(let terminal) = result else {
            Issue.record("run \(completionToken) did not settle: \(result)")
            throw FixtureError()
        }
        return terminal
    }

    // MARK: - The pending envelope's wire form

    /// How many freshly generated tokens the round-trip test renders and
    /// recognizes — enough that a token-dependent shape defect cannot hide.
    private static let wireFormTokenSampleCount = 32

    /// Asserts that `text` contains every element of `facts`, each after the
    /// previous one, and records which fact broke the sequence when it does
    /// not.
    private static func expect(_ text: String, saysInOrder facts: [String]) {
        var searchStart = text.startIndex
        for fact in facts {
            guard let found = text.range(of: fact, range: searchStart..<text.endIndex) else {
                Issue.record("\"\(fact)\" is missing, or out of order, in: \(text)")
                return
            }
            searchStart = found.upperBound
        }
    }

    @Test("every freshly generated token renders to a recognized envelope that decodes back to itself")
    func renderedEnvelopeRoundTripsForFreshTokens() throws {
        for _ in 0..<Self.wireFormTokenSampleCount {
            let completionToken = ULID.generate().ulidString
            let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

            #expect(PendingRunEnvelope.isRendered(text: rendered))
            let decoded = try Self.decodeEnvelope(rendered)
            #expect(decoded.pending)
            #expect(decoded.completionToken == completionToken)
        }
    }

    @Test("the rendered envelope's next field teaches the collect step: still running, do not answer, the exact wait snippet, and both run-plane states")
    func renderedEnvelopeTeachesTheCollectStep() throws {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let next = try Self.decodeEnvelope(rendered).next
        Self.expect(
            next,
            saysInOrder: [
                // The run has not finished.
                "still",
                // Do not answer, and do not invent the result.
                "not answer",
                "never invent",
                // The follow-up snippet, verbatim, carrying the real token.
                "return await wait(\"\(completionToken)\", 60)",
                // Where the result is once the run settles.
                "settled",
                "detail",
                // What to do when the follow-up wait comes back empty.
                "deadline_elapsed",
            ]
        )
    }

    @Test("the rendered envelope fits the run plane's detail cap, which truncates from the front")
    func renderedEnvelopeFitsTheRunPlaneDetailCap() {
        // `DetachingTool.detach` carries the rendered envelope as the
        // synthesized progress event's `detail`, and the mailbox bounds a
        // `detail` by keeping its TRAILING characters — so an envelope that
        // outgrew the cap would lose the completionToken the model needs.
        let rendered = PendingRunEnvelope(completionToken: ULID.generate().ulidString).rendered

        #expect(rendered.count <= ToolContext.terminalDetailTailLimit)
    }

    @Test("an envelope whose two token slots disagree is not recognized")
    func mismatchedTwinTokensAreRejected() throws {
        let completionToken = ULID.generate().ulidString
        let other = ULID.generate().ulidString
        #expect(other != completionToken)
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let firstSlot = try #require(rendered.range(of: completionToken))
        let lastSlot = try #require(rendered.range(of: completionToken, options: .backwards))
        #expect(firstSlot != lastSlot)

        for slot in [firstSlot, lastSlot] {
            let tampered = rendered.replacingCharacters(in: slot, with: other)
            #expect(tampered.count == rendered.count)
            #expect(!PendingRunEnvelope.isRendered(text: tampered))
        }
    }

    @Test("an envelope with anything added to or removed from it is not recognized")
    func alteredLengthIsRejected() {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let tampered = [
            rendered + " ",
            " " + rendered,
            String(rendered.dropLast()),
            String(rendered.dropFirst()),
            // Both slots shortened to a 25-character stub.
            rendered.replacingOccurrences(
                of: completionToken, with: String(completionToken.dropLast())
            ),
        ]

        for text in tampered {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }

    @Test("an envelope whose instruction prose was edited is not recognized, even at an unchanged length")
    func editedProseIsRejected() {
        let rendered = PendingRunEnvelope(completionToken: ULID.generate().ulidString).rendered

        // Same length, so only a content check can catch it.
        let tampered = rendered.replacingOccurrences(of: "detail", with: "result")

        #expect(tampered != rendered)
        #expect(tampered.count == rendered.count)
        #expect(!PendingRunEnvelope.isRendered(text: tampered))
    }

    @Test("an envelope whose twin slots hold a same-length non-ULID is not recognized")
    func nonULIDTokenSlotsAreRejected() {
        let completionToken = ULID.generate().ulidString
        let rendered = PendingRunEnvelope(completionToken: completionToken).rendered

        let notAToken = String(repeating: "!", count: ULID.stringLength)
        let tampered = rendered.replacingOccurrences(of: completionToken, with: notAToken)

        #expect(tampered.count == rendered.count)
        #expect(!PendingRunEnvelope.isRendered(text: tampered))
    }

    @Test("neither ordinary tool output nor an envelope missing its next instruction is recognized")
    func nonEnvelopeOutputIsRejected() {
        let completionToken = ULID.generate().ulidString

        let notEnvelopes = [
            "",
            "fast: x",
            "{}",
            // The instruction-free wire form this envelope used to render.
            "{\"pending\":true,\"completionToken\":\"\(completionToken)\"}",
            // The same facts as JSON, but not this envelope's byte shape.
            "{\"completionToken\":\"\(completionToken)\",\"pending\":true,\"next\":\"wait\"}",
        ]

        for text in notEnvelopes {
            #expect(!PendingRunEnvelope.isRendered(text: text))
        }
    }

    // MARK: - Inline fast path

    @Test("a fast tool returns its rendered output inline and posts no events at all")
    func inlineFastPathIsSilent() async throws {
        let harness = Self.makeHarness(
            wrapping: FastTool(),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.generousInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        #expect(rendered == "fast: x")
        #expect(await harness.sink.events.isEmpty)
        #expect(await harness.mailbox.parkedRuns().isEmpty)
    }

    // MARK: - Detachment slow path

    @Test("a slow tool detaches: pending envelope, mailbox entry, synthesized progress, one terminal upstream")
    func detachmentSlowPath() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(
            wrapping: GatedTool(gate: gate),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.shortInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "slow")
        )

        // The pending envelope: pending flag plus a ULID completion token.
        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(ULID(ulidString: envelope.completionToken) != nil)

        // The mailbox holds the parked run under that token, kind swiftTask.
        let status = await harness.mailbox.parkedRuns()
        #expect(status.count == 1)
        #expect(status.first?.completionToken == envelope.completionToken)
        #expect(status.first?.kind == .swiftTask)
        #expect(status.first?.tool == "gated_tool")

        // One synthesized progress at detachment, on the run's correlation.
        let eventsAtDetachment = await harness.sink.events
        #expect(eventsAtDetachment.count == 1)
        #expect(eventsAtDetachment.first?.kind == .progress)
        #expect(eventsAtDetachment.first?.correlationID == envelope.completionToken)
        #expect(eventsAtDetachment.first?.tool == "gated_tool")

        // Settle the run; the terminal event carries the rendered output in
        // detail, the token as correlationID, and outcome succeeded — and it
        // went upstream even though wait() collected it here.
        await gate.open()
        let terminal = try await Self.settledTerminal(
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

    @Test("waitSeconds 0 detaches immediately")
    func zeroWaitDetachesImmediately() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(
            wrapping: GatedTool(gate: gate),
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "detached")
        )

        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)
        #expect(await harness.mailbox.parkedRuns().count == 1)

        await gate.open()
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "gated: detached")
    }

    // MARK: - Per-call clocks (DetachmentParameterProviding)

    @Test("a per-call waitSeconds extracted from the arguments overrides the wrap-time default")
    func perCallWaitSecondsOverridesConfiguration() async throws {
        let gate = RunLatch()
        // Wrap-time wait is generous — only the per-call value can be what
        // detaches this call within the test's lifetime.
        let harness = Self.makeHarness(
            wrapping: PerCallClockTool(gate: gate),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.generousInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: ClockedArguments(value: "x", waitSeconds: Self.shortInterval)
        )

        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)

        await gate.open()
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .succeeded)
    }

    @Test("a per-call timeout overrides the wrap-time default")
    func perCallTimeoutOverridesConfiguration() async throws {
        let harness = Self.makeHarness(
            wrapping: PerCallTimeoutTool(timeoutSeconds: Self.shortInterval),
            configuration: DetachConfiguration(
                mode: .runToCompletion, timeout: Self.generousInterval
            )
        )

        await #expect(throws: DetachingToolError.self) {
            _ = try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("nil per-call clocks fall back to the wrap-time configuration")
    func nilPerCallClocksFallBackToConfiguration() async throws {
        let gate = RunLatch()
        let harness = Self.makeHarness(
            wrapping: NilClockTool(gate: gate),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.shortInterval
            )
        )

        // The provider returns (nil, nil), so the configured short wait is
        // what detaches this call.
        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)

        await gate.open()
        _ = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
    }

    // MARK: - Two clocks

    @Test("progress resets the per-call timeout: a tool that beats faster than the timeout survives past it")
    func progressResetsTimeout() async throws {
        // Total runtime (8 × 0.1 s) is well past the 0.5 s timeout, but each
        // beat arrives well inside a timeout window, so the run never times
        // out.
        let harness = Self.makeHarness(
            wrapping: HeartbeatTool(beats: 8, interval: 0.1),
            configuration: DetachConfiguration(mode: .runToCompletion, timeout: 0.5)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        #expect(rendered == "heartbeat done")
        let events = await harness.sink.events
        #expect(events.last?.kind == .completed)
        #expect(events.last?.outcome == .succeeded)
    }

    @Test("progress never extends waitSeconds: a beating tool still detaches, and later yields exactly one synthesized terminal")
    func progressDoesNotExtendWaitSeconds() async throws {
        // The tool beats every 0.05 s — far faster than the 0.3 s wait — so
        // if progress reset the wait clock the call would run to completion
        // (~1 s) and return its output inline. It must detach instead.
        let harness = Self.makeHarness(
            wrapping: HeartbeatTool(beats: 20, interval: 0.05),
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0.3)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)

        // The run posted its own progress, so no synthesized progress was
        // added at detachment — and it still gets exactly one synthesized
        // terminal at settlement.
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .succeeded)
        #expect(terminal.detail == "heartbeat done")

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.filter { $0.kind == .progress }.allSatisfy { $0.detail.hasPrefix("beat ") })
    }

    @Test("timeout expiry cancels the work and yields outcome timedOut, inline")
    func timeoutExpiryCancelsInline() async throws {
        let harness = Self.makeHarness(
            wrapping: SleepingTool(),
            configuration: DetachConfiguration(
                mode: .runToCompletion, timeout: Self.shortInterval
            )
        )

        await #expect(throws: DetachingToolError.self) {
            _ = try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    @Test("timeout expiry on a detached run settles it with outcome timedOut and exactly one terminal")
    func timeoutExpiryOnDetachedRun() async throws {
        let harness = Self.makeHarness(
            wrapping: SleepingTool(),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: 0, timeout: Self.shortInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )
        let envelope = try Self.decodeEnvelope(rendered)

        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .timedOut)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    // MARK: - Terminal-scoped synthesis matrix

    @Test("progress-only inline run still yields exactly one synthesized terminal")
    func progressOnlyInlineRunGetsSynthesizedTerminal() async throws {
        let harness = Self.makeHarness(
            wrapping: ProgressOnceTool(),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.generousInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        #expect(rendered == "progressed: x")
        let events = await harness.sink.events
        #expect(events.map(\.kind) == [.progress, .completed])
        #expect(events.last?.outcome == .succeeded)
        #expect(events.last?.detail == "progressed: x")
    }

    @Test("a tool that posts its own terminal event gets no duplicate")
    func ownTerminalToolGetsNoDuplicate() async throws {
        let harness = Self.makeHarness(
            wrapping: OwnTerminalTool(),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.generousInterval
            )
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )

        #expect(rendered == "own-terminal: x")
        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.detail == "my own terminal")
    }

    // MARK: - Exactly one .completed on the abnormal paths

    @Test("a tool that throws rethrows inline and yields exactly one terminal with outcome failed")
    func throwingToolYieldsOneFailedTerminal() async throws {
        let harness = Self.makeHarness(
            wrapping: ThrowingTool(),
            configuration: DetachConfiguration(
                mode: .detaching, waitSeconds: Self.generousInterval
            )
        )

        await #expect(throws: FixtureError.self) {
            _ = try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .failed)
    }

    @Test("cancelling a parked run settles it with outcome cancelled and exactly one terminal")
    func cancellingParkedRunYieldsOneCancelledTerminal() async throws {
        let harness = Self.makeHarness(
            wrapping: SleepingTool(),
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )
        let envelope = try Self.decodeEnvelope(rendered)

        let cancelResult = await harness.mailbox.cancel(
            completionToken: envelope.completionToken
        )
        #expect(cancelResult == .reported(.cancelled))

        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.outcome == .cancelled)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .cancelled)
    }

    // MARK: - Detachment off

    @Test("detachment-off mode runs to completion, never parks, and never returns a pending envelope")
    func detachmentOffRunsToCompletion() async throws {
        let gate = RunLatch()
        // waitSeconds is deliberately tiny: in run-to-completion mode it must
        // play no part at all.
        let harness = Self.makeHarness(
            wrapping: GatedTool(gate: gate),
            configuration: DetachConfiguration(
                mode: .runToCompletion, waitSeconds: 0.001
            )
        )

        let calling = Task {
            try await harness.detaching.call(
                arguments: DetachingArguments(value: "complete")
            )
        }
        // Give the call ample room to (wrongly) act on the tiny waitSeconds
        // before letting the tool finish.
        try await Task.sleep(nanoseconds: UInt64(Self.shortInterval * 1_000_000_000))
        #expect(await harness.mailbox.parkedRuns().isEmpty)
        await gate.open()

        let rendered = try await calling.value
        #expect(rendered == "gated: complete")
        #expect(await harness.mailbox.parkedRuns().isEmpty)
        // In-band silent success: no events at all.
        #expect(await harness.sink.events.isEmpty)
    }

    @Test("parked-run progress feeds the mailbox's run-plane snapshot")
    func parkedRunProgressFeedsStatus() async throws {
        let harness = Self.makeHarness(
            wrapping: HeartbeatTool(beats: 40, interval: 0.05),
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0.2)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )
        let envelope = try Self.decodeEnvelope(rendered)

        // Poll (bounded) until a beat lands in the parked run's status row.
        var observedDetail: String?
        for _ in 0..<1_000 {
            let status = await harness.mailbox.parkedRuns()
            if let detail = status.first?.latestProgressDetail {
                observedDetail = detail
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(observedDetail?.hasPrefix("beat ") == true)

        _ = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
    }

    // MARK: - Elicitation suspends the timeout

    /// Polls the mailbox (bounded) until an elicitation is pending and
    /// returns its id.
    private static func firstPendingElicitationId(
        in mailbox: SessionMailbox
    ) async throws -> ULID {
        for _ in 0..<1_000 {
            if let elicitationId = await mailbox.pendingElicitationIds().first {
                return elicitationId
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("no elicitation ever became pending")
        throw FixtureError()
    }

    @Test("a pending elicitation suspends the per-call timeout for as long as it is unanswered")
    func pendingElicitationSuspendsTimeout() async throws {
        let harness = Self.makeHarness(
            wrapping: ElicitOnceTool(),
            configuration: DetachConfiguration(
                mode: .runToCompletion, timeout: Self.shortInterval
            )
        )

        let calling = AnswerDrivenRun(waitingFor: "the detaching tool call blocked on its elicitation") {
            try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }
        let elicitationId = try await Self.firstPendingElicitationId(in: harness.mailbox)

        // Hold the answer across several full timeout windows: the pending
        // elicitation must suspend the timeout the whole time, so the run
        // still resolves to the answer instead of timing out.
        try await Task.sleep(
            nanoseconds: UInt64(Self.shortInterval * 3 * 1_000_000_000)
        )
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
        let harness = Self.makeHarness(
            wrapping: ElicitThenStallTool(),
            configuration: DetachConfiguration(
                mode: .runToCompletion, timeout: Self.shortInterval
            )
        )

        let calling = AnswerDrivenRun(waitingFor: "the detaching tool call blocked on its elicitation") {
            try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }
        let elicitationId = try await Self.firstPendingElicitationId(in: harness.mailbox)
        await harness.mailbox.respond(elicitationId: elicitationId, .decline)

        await #expect(throws: DetachingToolError.self) {
            _ = try await calling.deliveredAnswer()
        }

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The cooperative cancellation flag

    @Test("a cancelled run's cooperative flag reaches the tool through ToolContext.isCancelled")
    func cancellationFlagReachesTool() async throws {
        let witness = CancellationWitness()
        let harness = Self.makeHarness(
            wrapping: CancellationFlagPollingTool(witness: witness),
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0)
        )

        let rendered = try await harness.detaching.call(
            arguments: DetachingArguments(value: "x")
        )
        let envelope = try Self.decodeEnvelope(rendered)

        let cancelResult = await harness.mailbox.cancel(
            completionToken: envelope.completionToken
        )
        #expect(cancelResult == .reported(.cancelled))

        // The tool never observes structured cancellation — only the flag —
        // and chooses to return normally once it flips: an honest success.
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: harness.mailbox
        )
        #expect(terminal.detail == "observed cancellation")
        #expect(terminal.outcome == .succeeded)
        #expect(await witness.observed)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
    }

    @Test("timeout expiry also raises the cooperative flag the tool observes")
    func timeoutSetsCancellationFlag() async throws {
        let witness = CancellationWitness()
        let harness = Self.makeHarness(
            wrapping: CancellationFlagPollingTool(witness: witness),
            configuration: DetachConfiguration(
                mode: .runToCompletion, timeout: Self.shortInterval
            )
        )

        await #expect(throws: DetachingToolError.self) {
            _ = try await harness.detaching.call(
                arguments: DetachingArguments(value: "x")
            )
        }

        // The race resolved as timedOut; the tool keeps polling until the
        // flag the timeout raised reaches it. Wait (bounded) for the mark.
        var observed = false
        for _ in 0..<1_000 {
            if await witness.observed {
                observed = true
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(observed)

        let events = await harness.sink.events
        #expect(events.filter { $0.kind == .completed }.count == 1)
        #expect(events.last?.outcome == .timedOut)
    }

    // MARK: - The untyped ToolDetachment entry point

    @Test("ToolDetachment.wrapping discovers a String-output tool from any Tool and detaches it")
    func factoryWrapsStringOutputTool() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sink = RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: GatedTool(gate: gate),
            sessionID: ULID.generate(),
            mailbox: mailbox,
            sink: sink,
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0)
        )

        let detaching = try #require(wrapped as? DetachingTool<DetachingArguments>)
        let rendered = try await detaching.call(
            arguments: DetachingArguments(value: "factory")
        )
        let envelope = try Self.decodeEnvelope(rendered)
        #expect(envelope.pending)

        await gate.open()
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: mailbox
        )
        #expect(terminal.detail == "gated: factory")
    }

    @Test("ToolDetachment.wrapping wraps a non-String-output tool in the binding-only ContextBindingTool")
    func factoryBindsNonStringOutputTool() async throws {
        let sink = RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: NonStringOutputTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            configuration: DetachConfiguration(mode: .detaching)
        )

        let binding = try #require(
            wrapped as? ContextBindingTool<DetachingArguments, NonStringToolOutput>)
        let output = try await binding.call(arguments: DetachingArguments(value: "silent"))

        // The wrapped tool's own output passes through unchanged, and a
        // silent run posts nothing at all: binding-only, with none of the
        // pending-envelope/park machinery's synthesized events.
        #expect(output.text == "ignored")
        #expect(await sink.events.isEmpty)
    }

    @Test("a non-String-output tool's ambient posts carry its own tool identity and a fresh per-call correlationID")
    func nonStringOutputToolAmbientPostsCarryPerCallIdentity() async throws {
        let sink = RecordingSink()
        let wrapped = ToolDetachment.wrapping(
            tool: AmbientNonStringOutputTool(),
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            configuration: DetachConfiguration(mode: .detaching)
        )

        let binding = try #require(
            wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let first = try await binding.call(arguments: AmbientToolArguments(value: "one"))
        let second = try await binding.call(arguments: AmbientToolArguments(value: "two"))

        let events = await sink.events
        #expect(events.map(\.detail) == ["one", "two"])
        #expect(events.map(\.tool) == ["ambient-non-string", "ambient-non-string"])
        #expect(events.map(\.op) == ["ambient-non-string", "ambient-non-string"])
        // Run scope, never session scope: each call minted its own token,
        // and each event's correlationID is exactly the token its own call
        // observed as the ambient completionToken.
        #expect(events.map(\.correlationID) == [first.text, second.text])
        #expect(first.text != second.text)
        #expect(ULID(first.text) != nil)
    }

    @Test("ToolDetachment.wrapping inheriting a ToolContext binds on that context's session plane")
    func factoryInheritsAmbientContext() async throws {
        let sink = RecordingSink()
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
            configuration: DetachConfiguration(mode: .detaching)
        )

        let binding = try #require(
            wrapped as? ContextBindingTool<AmbientToolArguments, NonStringToolOutput>)
        let inner = try await binding.call(arguments: AmbientToolArguments(value: "inherited"))

        // The same decision and the same stamping the mailbox-taking overload
        // makes — the inner call is bound under its own identity, on a fresh
        // correlation of its own rather than the outer run's token.
        let events = await sink.events
        #expect(events.map(\.detail) == ["inherited"])
        #expect(events.map(\.tool) == ["ambient-non-string"])
        #expect(events.map(\.correlationID) == [inner.text])
        #expect(inner.text != outer.completionToken)
    }

    @Test("ToolDetachment.wrapping inheriting a ToolContext parks the run in that context's own mailbox")
    func factoryInheritsMailboxAndSessionIdentity() async throws {
        let gate = RunLatch()
        let mailbox = SessionMailbox()
        let sessionID = ULID.generate()
        let sink = RecordingSink()
        let outer = ToolContext(
            stamping: GatedSessionIdentityTool(gate: gate),
            sessionID: sessionID,
            mailbox: mailbox,
            sink: sink,
            completionToken: SessionMailbox.makeCompletionToken(),
            isCancelled: { false }
        )
        let wrapped = ToolDetachment.wrapping(
            tool: GatedSessionIdentityTool(gate: gate),
            inheriting: outer,
            sink: sink,
            configuration: DetachConfiguration(mode: .detaching, waitSeconds: 0)
        )

        let detaching = try #require(wrapped as? DetachingTool<DetachingArguments>)
        let rendered = try await detaching.call(
            arguments: DetachingArguments(value: "inherited")
        )
        let envelope = try Self.decodeEnvelope(rendered)

        // The run parked in the mailbox the inherited context carries — a
        // mailbox this call never named.
        let parked = await mailbox.parkedRuns()
        #expect(parked.map(\.completionToken) == [envelope.completionToken])

        await gate.open()
        let terminal = try await Self.settledTerminal(
            of: envelope.completionToken, in: mailbox
        )
        // The inner run ran on the inherited session plane: the identity it
        // read off its own ambient context is the outer context's.
        #expect(terminal.detail == sessionID.ulidString)
        #expect(terminal.outcome == .succeeded)
    }
}
