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

    /// A deadline a test treats as "never elapses within this test".
    static let generousInterval: TimeInterval = 30

    // MARK: - Sink

    /// A sink that records every posted event, in order, and every posted
    /// ``ToolCallReport``, in order.
    actor RecordingSink: OperationEventSink, ToolCallReportSink {
        private(set) var events: [OperationEvent] = []

        /// Every report a closing call posted, in post order.
        private(set) var reports: [ToolCallReport] = []

        /// Signals after each event or report that the sink records.
        nonisolated let changes = ChangeSignal()

        func post(event: OperationEvent) {
            events.append(event)
            changes.signal()
        }

        func post(report: ToolCallReport) {
            reports.append(report)
            changes.signal()
        }
    }

    // MARK: - Harness

    /// One test's wiring: the run plane, the sink, and the mounted tool.
    struct Harness<Mounted: Tool> {
        let runPlane: RunPlane
        let sink: RecordingSink
        let mounted: Mounted
    }

    /// Mounts `tool` in a `BackgroundToolRunner` over a fresh run plane and
    /// sink.
    ///
    /// - Parameters:
    ///   - tool: The tool to mount.
    ///   - timeout: The timeout with no progress, or `nil` for none.
    ///   - inlineSettleGrace: The settle period of the site, in seconds. The
    ///     default `0` gives the pending envelope at once, also for a fast
    ///     tool, so a test can examine the background path.
    /// - Returns: The wiring of the test.
    static func backgroundHarness<Arguments: ConvertibleFromGeneratedContent & Sendable>(
        wrapping tool: any Tool<Arguments, String>,
        timeout: TimeInterval? = nil,
        inlineSettleGrace: TimeInterval = 0
    ) -> Harness<BackgroundToolRunner<Arguments>> {
        let runPlane = RunPlane()
        let sink = RecordingSink()
        let mounted = BackgroundToolRunner(
            wrapping: tool,
            site: MountSite(
                sessionID: ULID.generate(), runPlane: runPlane, sink: sink, inlineSettleGrace: inlineSettleGrace),
            timeout: timeout
        )
        return Harness(runPlane: runPlane, sink: sink, mounted: mounted)
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
            mountTimeout: nil,
            inlineSettleDeadline: nil
        )
    }

    // MARK: - Envelope and settlement helpers

    /// The envelope's decoded shape. Only a run that continues past its
    /// settle period answers with an envelope, so `pending` is always `true`.
    struct DecodedEnvelope: Decodable {
        let pending: Bool
        let completionToken: String
        let next: String
    }

    /// The error a helper throws when the fact it waits for never comes.
    struct FixtureError: Error, Equatable {}

    /// Decodes the pending envelope out of a returned rendered output.
    static func decodeEnvelope(_ rendered: String) throws -> DecodedEnvelope {
        try JSONDecoder().decode(DecodedEnvelope.self, from: Data(rendered.utf8))
    }

    /// Waits for the settlement of the run through the run plane, with no
    /// deadline, and returns its terminal event.
    ///
    /// - Parameters:
    ///   - completionToken: The completion token of the run.
    ///   - runPlane: The run plane of the run.
    /// - Returns: The terminal event of the run.
    /// - Throws: ``FixtureError`` when the wait ends with no settlement (a
    ///   cancel of the test, or an unknown token).
    static func settledTerminal(
        of completionToken: String, in runPlane: RunPlane
    ) async throws -> OperationEvent {
        let result = await runPlane.wait(completionToken: completionToken, seconds: nil)
        guard case .settled(let terminal) = result else {
            Issue.record("run \(completionToken) did not settle: \(result)")
            throw FixtureError()
        }
        return terminal
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

    /// Opens `entered` when it is not `nil`, then blocks on `gate` until the
    /// test opens it.
    ///
    /// The body of a call does this first step, so a test that waits for
    /// `entered` knows that the call runs the body of the tool.
    ///
    /// - Parameters:
    ///   - entered: The latch to open when the body starts, or `nil`.
    ///   - gate: The latch that the body waits on.
    static func enterAndHold(_ entered: RunLatch?, on gate: RunLatch) async {
        await entered?.open()
        await gate.waitUntilOpen()
    }

    /// Blocks on a ``RunLatch`` until the test opens it.
    struct GatedTool: Tool {
        let name = "gated_tool"
        let description = "blocks until its gate opens"
        let gate: RunLatch

        /// The latch the call opens when its body starts, or `nil`.
        var entered: RunLatch?

        func call(arguments: MountArguments) async throws -> String {
            await enterAndHold(entered, on: gate)
            return "gated: \(arguments.value)"
        }
    }

    /// Posts no progress and blocks on its gate, then returns. The test opens
    /// the gate, so the run is quiet for as long as the test wants.
    struct QuietTool: Tool {
        let name = "quiet_tool"
        let description = "runs for a time with no progress, then returns"

        /// The latch the call opens when its body starts.
        let entered: RunLatch

        /// The latch that ends the quiet run.
        let gate: RunLatch

        func call(arguments: MountArguments) async throws -> String {
            await enterAndHold(entered, on: gate)
            return "quiet: \(arguments.value)"
        }
    }

    /// Blocks on a gate and declares ``ToolMount/synchronous``.
    struct DeclaredRunToCompletionRunner: Tool, BackgroundTool {
        let name = "declared_run_to_completion_tool"
        let description = "declares the mount it cannot work without"
        let gate: RunLatch

        /// The latch the call opens when its body starts, or `nil`.
        var entered: RunLatch?

        var mount: ToolMount? { .synchronous }

        func call(arguments: MountArguments) async throws -> String {
            await enterAndHold(entered, on: gate)
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

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

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
    /// settles inside that time answers with its own output.
    struct InlineGraceTool: Tool, BackgroundTool {
        let name = "inline_grace_tool"
        let description = "waits a short time for its own run before it answers"
        let gate: RunLatch
        let grace: TimeInterval

        /// The output this tool returns for `value`.
        static func output(for value: String) -> String {
            "inline: \(value)"
        }

        var inlineSettleGrace: TimeInterval { grace }

        func call(arguments: MountArguments) async throws -> String {
            await gate.waitUntilOpen()
            return Self.output(for: arguments.value)
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

        /// No wait: each call answers with its pending envelope at once.
        var inlineSettleGrace: TimeInterval { 0 }

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
