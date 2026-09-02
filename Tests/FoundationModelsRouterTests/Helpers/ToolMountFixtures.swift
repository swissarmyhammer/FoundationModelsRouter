import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The arguments every mount-layer fixture tool takes.
@Generable
struct MountArguments {
    let value: String
}

/// The fixtures the mount-layer suites share — `RunToCompletionRunnerTests`,
/// `BackgroundToolRunnerTests`, `ToolMountingTests`, and
/// `PendingRunEnvelopeTests` — so each tool and helper lives in one place.
enum MountFixtures {
    // MARK: - Intervals

    /// A timeout, or a hold, short enough to keep a suite fast but long
    /// enough that a fixture never spuriously elapses it.
    static let shortInterval: TimeInterval = 0.2

    /// A deadline a test treats as "never elapses within this test".
    static let generousInterval: TimeInterval = 30

    /// The ceiling on any await a test performs against the mailbox.
    static let settlementDeadline: TimeInterval = 30

    /// One hour in nanoseconds: the sleep a tool that must never return takes.
    static let hourInNanoseconds: UInt64 = 3_600_000_000_000

    /// The pause between two polls of a run-plane fact, in nanoseconds.
    static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// How many polls a bounded poll makes before it gives up.
    static let pollAttempts = 1_000

    // MARK: - Sink

    /// A sink that records every posted event, in order.
    actor RecordingSink: OperationEventSink {
        private(set) var events: [OperationEvent] = []

        func post(event: OperationEvent) {
            events.append(event)
        }
    }

    // MARK: - Harness

    /// One test's wiring: the mailbox, the sink, and the mounted tool.
    struct Harness<Mounted: Tool> {
        let mailbox: SessionMailbox
        let sink: RecordingSink
        let mounted: Mounted
    }

    /// Mounts `tool` in a ``BackgroundToolRunner`` over a fresh mailbox and sink.
    static func backgroundHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = ToolMount.defaultTimeoutSeconds
    ) -> Harness<BackgroundToolRunner<Arguments>> {
        let mailbox = SessionMailbox()
        let sink = RecordingSink()
        let mounted = BackgroundToolRunner(
            wrapping: tool, sessionID: ULID.generate(), mailbox: mailbox, sink: sink, timeout: timeout
        )
        return Harness(mailbox: mailbox, sink: sink, mounted: mounted)
    }

    /// Mounts `tool` in a ``RunToCompletionRunner`` over a fresh mailbox and sink.
    static func runToCompletionHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = ToolMount.defaultTimeoutSeconds
    ) -> Harness<RunToCompletionRunner<Arguments>> {
        let mailbox = SessionMailbox()
        let sink = RecordingSink()
        let mounted = RunToCompletionRunner(
            wrapping: tool, sessionID: ULID.generate(), mailbox: mailbox, sink: sink, timeout: timeout
        )
        return Harness(mailbox: mailbox, sink: sink, mounted: mounted)
    }

    /// One call's internal run, the body both runners share, over a fresh
    /// mailbox and `sink`.
    ///
    /// - Parameters:
    ///   - tool: The tool the run calls.
    ///   - arguments: The call's arguments, read for a per-call timeout.
    ///   - sink: The sink the run's events funnel into.
    /// - Returns: The prepared run. Call `open()` and then `execute(arguments:)`.
    static func toolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        arguments: Arguments,
        sink: RecordingSink
    ) -> ToolRun<Arguments> {
        ToolRun(
            wrapped: tool,
            arguments: arguments,
            sessionID: ULID.generate(),
            mailbox: SessionMailbox(),
            sink: sink,
            op: nil,
            mountTimeout: ToolMount.defaultTimeoutSeconds
        )
    }

    // MARK: - Envelope and settlement helpers

    /// The pending envelope's decoded shape.
    struct DecodedEnvelope: Decodable {
        let pending: Bool
        let completionToken: String
        let next: String
    }

    /// The error a helper throws when the fact it polls for never appears.
    struct FixtureError: Error, Equatable {}

    /// Decodes the pending envelope out of a returned rendered output.
    static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// Awaits the run's settlement through the mailbox and returns its
    /// terminal event.
    static func settledTerminal(
        of completionToken: String, in mailbox: SessionMailbox
    ) async throws -> OperationEvent {
        let result = await mailbox.wait(completionToken: completionToken, seconds: settlementDeadline)
        guard case .settled(let terminal) = result else {
            Issue.record("run \(completionToken) did not settle: \(result)")
            throw FixtureError()
        }
        return terminal
    }

    /// Polls the mailbox (bounded) until an elicitation is pending and
    /// returns its id.
    static func firstPendingElicitationId(in mailbox: SessionMailbox) async throws -> ULID {
        for _ in 0..<pollAttempts {
            if let elicitationId = await mailbox.pendingElicitationIds().first {
                return elicitationId
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        Issue.record("no elicitation ever became pending")
        throw FixtureError()
    }

    /// Polls `fact` (bounded) until it returns a value.
    static func poll<Value>(_ fact: () async -> Value?) async throws -> Value? {
        for _ in 0..<pollAttempts {
            if let value = await fact() {
                return value
            }
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return nil
    }

    // MARK: - Tools

    /// Returns immediately.
    struct FastTool: Tool {
        let name = "fast_tool"
        let description = "returns immediately"

        func call(arguments: MountArguments) async throws -> String {
            "fast: \(arguments.value)"
        }
    }

    /// Returns at once and reports whether its own run was already tracked in
    /// the mailbox when its body started.
    struct TrackedAtStartTool: Tool {
        /// The output when the run was tracked before the body ran.
        static let trackedOutput = "tracked at start"

        let name = "tracked_at_start_tool"
        let description = "reports whether its run was tracked when it started"

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            let tracked = await context.mailbox.backgroundRuns().map(\.completionToken)
            return tracked.contains(context.completionToken) ? Self.trackedOutput : "untracked at start"
        }
    }

    /// Blocks on a ``RunLatch`` until the test opens it.
    struct GatedTool: Tool {
        let name = "gated_tool"
        let description = "blocks until its gate opens"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "gated: \(arguments.value)"
        }
    }

    /// Throws ``FixtureError`` immediately.
    struct ThrowingTool: Tool {
        let name = "throwing_tool"
        let description = "throws immediately"

        func call(arguments: MountArguments) async throws -> String {
            throw FixtureError()
        }
    }

    /// Sleeps cooperatively until cancelled: `Task.sleep` throws
    /// `CancellationError` the moment the run's cancellation lands.
    struct SleepingTool: Tool {
        let name = "sleeping_tool"
        let description = "sleeps until cancelled"

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }
    }

    /// Posts one progress event of its own, then returns.
    struct ProgressOnceTool: Tool {
        let name = "progress_once_tool"
        let description = "posts one progress event then returns"

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.progress("halfway")
            return "progressed: \(arguments.value)"
        }
    }

    /// Posts its own terminal `.completed` event, then returns.
    struct OwnTerminalTool: Tool {
        let name = "own_terminal_tool"
        let description = "posts its own terminal event then returns"

        func call(arguments: MountArguments) async throws -> String {
            await ToolContext.current?.post(
                OperationEvent(
                    tool: "", op: "", correlationID: "", kind: .completed,
                    detail: "my own terminal", outcome: .succeeded
                )
            )
            return "own-terminal: \(arguments.value)"
        }
    }

    /// Posts progress every `interval` seconds for `beats` beats, then returns.
    struct HeartbeatTool: Tool {
        let name = "heartbeat_tool"
        let description = "posts periodic progress then returns"
        let beats: Int
        let interval: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            for beat in 0..<beats {
                try await Task.sleep(for: .seconds(interval))
                await ToolContext.current?.progress("beat \(beat)")
            }
            return "heartbeat done"
        }
    }

    /// Sleeps forever and supplies a per-call `timeout` through
    /// ``BackgroundTool``.
    struct PerCallTimeoutTool: Tool, BackgroundTool {
        let name = "per_call_timeout_tool"
        let description = "supplies a short per-call timeout"
        let timeoutSeconds: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }

        func timeout(from arguments: GeneratedContent) -> TimeInterval? {
            timeoutSeconds
        }
    }

    /// Sleeps forever and supplies a `nil` per-call timeout.
    struct NilTimeoutTool: Tool, BackgroundTool {
        let name = "nil_timeout_tool"
        let description = "supplies no per-call timeout at all"

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }

        func timeout(from arguments: GeneratedContent) -> TimeInterval? {
            nil
        }
    }

    /// Blocks on a gate and declares ``ToolMount/synchronousUnbounded``.
    struct DeclaredRunToCompletionRunner: Tool, BackgroundTool {
        let name = "declared_run_to_completion_tool"
        let description = "declares the mount it cannot work without"
        let gate: RunLatch

        var mount: ToolMount? { .synchronousUnbounded }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "declared: \(arguments.value)"
        }
    }

    /// Blocks on a gate and declares background with no timeout — the
    /// shape of a shell tool or an agent tool.
    struct DeclaredBackgroundToolRunner: Tool, BackgroundTool {
        let name = "declared_background_tool"
        let description = "declares background and is handed back as a token at once"
        let gate: RunLatch

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "background: \(arguments.value)"
        }
    }

    /// Blocks on a gate and supplies its own collect sentence.
    struct CollectSentenceTool: Tool, BackgroundTool {
        let name = "collect_sentence_tool"
        let description = "names its own collect step"
        let gate: RunLatch

        /// The sentence this tool renders for `completionToken`.
        static func collectInstruction(forCompletionToken completionToken: String) -> String {
            "Call the fetch tool with ticket \"\(completionToken)\" to read the result."
        }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return "collected: \(arguments.value)"
        }

        func collectInstruction(forCompletionToken completionToken: String) -> String {
            Self.collectInstruction(forCompletionToken: completionToken)
        }
    }

    /// The one question the elicitation fixtures ask.
    static func proceedRequest() -> ElicitationRequest {
        ElicitationRequest(
            message: "Proceed?",
            elicitationId: ULID.generate(),
            requestedSchema: ElicitationRequestedSchema(
                properties: ["ok": .boolean(ElicitationBooleanSchema())]
            )
        )
    }

    /// Asks one question through `ToolContext.elicit` and returns the
    /// action it was answered with.
    struct ElicitOnceTool: Tool {
        let name = "elicit_once_tool"
        let description = "asks one question then returns"

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            let response = try await context.elicit(proceedRequest())
            return "answered: \(response.action.rawValue)"
        }
    }

    /// Elicits, then stalls forever.
    struct ElicitThenStallTool: Tool {
        let name = "elicit_then_stall_tool"
        let description = "asks one question then stalls forever"

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            _ = try await context.elicit(proceedRequest())
            try await Task.sleep(nanoseconds: hourInNanoseconds)
            return "never returned"
        }
    }

    /// Records that a tool observed the run's cooperative cancellation flag.
    actor CancellationWitness {
        private(set) var observed = false

        func mark() {
            observed = true
        }
    }

    /// Polls `ToolContext.isCancelled` — never structured task cancellation —
    /// and returns normally the moment the flag flips, marking the witness.
    struct CancellationFlagPollingTool: Tool {
        let name = "flag_polling_tool"
        let description = "returns when the ambient cancellation flag flips"
        let witness: CancellationWitness

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return "no context" }
            for _ in 0..<pollAttempts {
                if context.isCancelled {
                    await witness.mark()
                    return "observed cancellation"
                }
                // Deliberately swallow the cancellation error: this tool
                // cooperates through the flag alone.
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
            return "never cancelled"
        }
    }

    /// A silent non-`String`-output tool.
    struct NonStringOutputTool: Tool {
        let name = "non_string_output_tool"
        let description = "returns a non-String PromptRepresentable"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            NonStringToolOutput(text: "ignored")
        }
    }

    /// Blocks on a ``RunLatch`` and then returns the ambient run's session identity.
    struct GatedSessionIdentityTool: Tool {
        let name = "gated_session_identity_tool"
        let description = "returns the ambient context's session identity once its gate opens"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return ToolContext.current?.sessionID.ulidString ?? "unbound"
        }
    }

    // MARK: - Attachments

    /// The first record the attaching fixtures hand to their run.
    static let firstAttachment = ToolCallAttachment(
        schemaName: "FileChangeSet",
        contentJSON: #"{"changes":[{"path":"Sources/App.swift","kind":"modified"}]}"#
    )

    /// The second record the attaching fixtures hand to their run.
    static let secondAttachment = ToolCallAttachment(
        schemaName: "CommandExit",
        contentJSON: #"{"status":0}"#
    )

    /// The records every attaching fixture hands to its run, in call order.
    static let attachmentsInCallOrder = [firstAttachment, secondAttachment]

    /// Hands ``firstAttachment`` and then ``secondAttachment`` to the ambient
    /// context. Does nothing when no context is bound.
    static func attachInCallOrder() {
        ToolContext.current?.attach(firstAttachment)
        ToolContext.current?.attach(secondAttachment)
    }

    /// Whether `text` carries any part of an attaching fixture's records: the
    /// schema name or the JSON document.
    ///
    /// - Parameter text: The rendered output or event detail to read.
    /// - Returns: `true` when the text names a record.
    static func isAttachmentMentioned(in text: String) -> Bool {
        attachmentsInCallOrder.contains { attachment in
            text.contains(attachment.schemaName) || text.contains(attachment.contentJSON)
        }
    }

    /// Attaches both records through the ambient context, then returns.
    struct AttachingTool: Tool {
        let name = "attaching_tool"
        let description = "attaches two records then returns"

        func call(arguments: MountArguments) async throws -> String {
            attachInCallOrder()
            return "attached: \(arguments.value)"
        }
    }

    /// Attaches ``firstAttachment``, blocks on its gate, attaches
    /// ``secondAttachment``, then returns. The second record therefore lands
    /// after the test opens the gate.
    struct GatedAttachingTool: Tool {
        let name = "gated_attaching_tool"
        let description = "attaches one record, waits for its gate, then attaches a second"
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            ToolContext.current?.attach(firstAttachment)
            await gate.waitUntilOpen()
            ToolContext.current?.attach(secondAttachment)
            return "attached late: \(arguments.value)"
        }
    }

    /// The non-`String`-output twin of ``AttachingTool``: attaches both records
    /// through the ambient context, then returns its text.
    struct AttachingNonStringOutputTool: Tool {
        let name = "attaching_non_string_output_tool"
        let description = "attaches two records then returns a non-String output"

        func call(arguments: MountArguments) async throws -> NonStringToolOutput {
            attachInCallOrder()
            return NonStringToolOutput(text: "attached: \(arguments.value)")
        }
    }
}
