import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// The arguments every mount-layer fixture tool takes.
@Generable
struct MountArguments {
    let value: String
}

/// The fixtures the mount-layer suites share — `SessionMountCompositionTests`,
/// `ToolInvocationLivenessTests`, `MountedRunSweptTerminalTests` and the other
/// suites that mount a tool on a session — so each tool and helper lives in
/// one place.
enum MountFixtures {
    // MARK: - Intervals

    /// A timeout, or a hold, short enough to keep a suite fast but long
    /// enough that a fixture never spuriously elapses it.
    static let shortInterval: TimeInterval = 0.2

    /// A deadline a test treats as "never elapses within this test".
    static let generousInterval: TimeInterval = 30

    /// The ceiling on any await a test performs against the run plane.
    static let settlementDeadline: TimeInterval = 30

    /// The pause between two polls of a run-plane fact, in nanoseconds.
    static let pollIntervalNanoseconds: UInt64 = 5_000_000

    /// How many polls a bounded poll makes before it gives up.
    static let pollAttempts = 1_000

    // MARK: - Sink

    /// A sink that records every posted event, in order, and every posted
    /// ``ToolCallReport``, in order.
    actor RecordingSink: OperationEventSink, ToolCallReportSink {
        private(set) var events: [OperationEvent] = []

        /// Every report a closing call posted, in post order.
        private(set) var reports: [ToolCallReport] = []

        func post(event: OperationEvent) {
            events.append(event)
        }

        func post(report: ToolCallReport) {
            reports.append(report)
        }
    }

    // MARK: - Harness

    /// One test's wiring: the run plane, the sink, and the mounted tool.
    struct Harness<Mounted: Tool> {
        let mailbox: RunPlane
        let sink: RecordingSink
        let mounted: Mounted
    }

    /// Mounts `tool` in a `BackgroundToolRunner` over a fresh run plane and
    /// sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - timeout: The timeout with no progress, or `nil` for none.
    /// - Returns: The wiring of the test.
    static func backgroundHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil
    ) -> Harness<BackgroundToolRunner<Arguments>> {
        let mailbox = RunPlane()
        let sink = RecordingSink()
        let mounted = BackgroundToolRunner(
            wrapping: tool, site: MountSite(sessionID: ULID.generate(), runPlane: mailbox, sink: sink),
            timeout: timeout
        )
        return Harness(mailbox: mailbox, sink: sink, mounted: mounted)
    }

    /// One call's internal run, the body both runners share, over a fresh
    /// run plane and `sink`.
    ///
    /// - Parameters:
    ///   - tool: The tool the run calls.
    ///   - arguments: The call's arguments, read for a per-call timeout.
    ///   - sink: The sink the run's events funnel into, and the sink the
    ///     run's records and report go to.
    /// - Returns: The prepared run. Call `open()` and then `execute(arguments:)`.
    static func toolRun<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        arguments: Arguments,
        sink: any OperationEventSink
    ) -> ToolRun<Arguments> {
        ToolRun(
            wrapped: tool,
            arguments: arguments,
            site: MountSite(sessionID: ULID.generate(), runPlane: RunPlane(), sink: sink),
            mountTimeout: nil
        )
    }

    // MARK: - Envelope and settlement helpers

    /// The envelope's decoded shape. A run still going carries no `outcome`
    /// and no `detail`; a run that settled inside its tool's grace carries
    /// both.
    struct DecodedEnvelope: Decodable {
        let pending: Bool
        let completionToken: String
        let outcome: String?
        let detail: String?
        let next: String
    }

    /// The error a helper throws when the fact it polls for never appears.
    struct FixtureError: Error, Equatable {}

    /// Decodes the pending envelope out of a returned rendered output.
    static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// Awaits the run's settlement through the run plane and returns its
    /// terminal event.
    static func settledTerminal(
        of completionToken: String, in mailbox: RunPlane
    ) async throws -> OperationEvent {
        let result = await mailbox.wait(completionToken: completionToken, seconds: settlementDeadline)
        guard case .settled(let terminal) = result else {
            Issue.record("run \(completionToken) did not settle: \(result)")
            throw FixtureError()
        }
        return terminal
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

    /// Sleeps for `duration` seconds and posts no progress, then returns.
    struct QuietTool: Tool {
        let name = "quiet_tool"
        let description = "runs for a time with no progress, then returns"
        let duration: TimeInterval

        func call(arguments: MountArguments) async throws -> String {
            try await Task.sleep(for: .seconds(duration))
            return "quiet: \(arguments.value)"
        }
    }

    /// Blocks on a gate and declares ``ToolMount/synchronous``.
    struct DeclaredRunToCompletionRunner: Tool, BackgroundTool {
        let name = "declared_run_to_completion_tool"
        let description = "declares the mount it cannot work without"
        let gate: RunLatch

        var mount: ToolMount? { .synchronous }

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

    /// Waits for its gate, then returns. Declares a grace, so a run that
    /// settles inside that time is answered in the call's own envelope.
    struct InlineGraceTool: Tool, BackgroundTool {
        let name = "inline_grace_tool"
        let description = "waits a short time for its own run before it answers"
        let gate: RunLatch
        let grace: TimeInterval

        /// The output this tool returns for `value`.
        static func output(for value: String) -> String {
            "inline: \(value)"
        }

        /// The sentence this tool renders for a settled `completionToken`.
        static func resultInstruction(forCompletionToken completionToken: String) -> String {
            "Run \"\(completionToken)\" is done. Read the detail field beside this sentence."
        }

        var inlineSettleGrace: TimeInterval? { grace }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return Self.output(for: arguments.value)
        }

        func resultInstruction(forCompletionToken completionToken: String) -> String {
            Self.resultInstruction(forCompletionToken: completionToken)
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

    /// ``GatedAttachingTool`` with the background mount declared for itself,
    /// so a session mounts it in `BackgroundToolRunner` with no configuration
    /// of its own. The call returns to the model at once, and the run attaches
    /// its second record after the test opens the gate.
    struct DeclaredBackgroundAttachingTool: Tool, BackgroundTool {
        let name = "declared_background_attaching_tool"
        let description = "declares background, attaches one record, waits for its gate, then attaches a second"

        /// The gated tool this tool runs. The attaching body lives there.
        private let gated: GatedAttachingTool

        /// Creates the tool over `gate`.
        ///
        /// - Parameter gate: The gate the run waits on between its two records.
        init(gate: RunLatch) {
            gated = GatedAttachingTool(gate: gate)
        }

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: nil)
        }

        func call(arguments: MountArguments) async throws -> String {
            try await gated.call(arguments: arguments)
        }
    }

    /// Mounts ``AttachingTool`` on its own run's context through
    /// ``ToolContext/mount(_:op:as:)`` and calls it in band. It attaches
    /// nothing itself, so every record on its run came from the nested call.
    struct NestingAttachingTool: Tool {
        let name = "nesting_attaching_tool"
        let description = "mounts the attaching tool on its own context and calls it in band"

        /// The output when no context is bound. A test never sees it.
        static let noContextOutput = "no context"

        func call(arguments: MountArguments) async throws -> String {
            guard let context = ToolContext.current else { return Self.noContextOutput }
            return try await context.mount(AttachingTool()).call(arguments: arguments)
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
