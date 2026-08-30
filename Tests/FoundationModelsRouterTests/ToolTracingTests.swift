import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^fypc46z: every tool call a turn makes opens one OpenTelemetry
/// span through `swift-distributed-tracing`, nested in that turn's own span.
///
/// There is no single shared call body to instrument, so the contract is held at
/// the three outermost decorators ``ToolMounting`` can mount — the foreground
/// ``RunToCompletionRunner``, the ``BackgroundToolRunner``, and the binding-only
/// ``ContextBindingTool`` — and this suite drives one scripted turn through each
/// of them. It also holds the rule that the pass-through ``TokenCappingTool``
/// opens no span of its own, so a capped tool is still measured once.
///
/// The rule that no attribute carries the caller's own content lives in
/// ``SpanContentSafetyTests``, which names no span and therefore already
/// measures this one.
///
/// Everything runs over stubs — a stub ``ModelLoader``, a
/// ``ScriptedToolCallingModel`` and an `InMemoryTracer` — so the suite needs no
/// network, no GPU and no bootstrapped tracing backend.
@Suite("Tool tracing")
struct ToolTracingTests {
    /// The span name every tool call opens.
    private static let toolSpanName = "FoundationModelsRouter.tool"

    /// The span name the enclosing turn opens.
    private static let turnSpanName = "FoundationModelsRouter.turn"

    /// The step name the second call of a two-call round names, beside
    /// ``ScriptedToolFixture/firstStepName`` for the first.
    private static let secondStepName = "TWO"

    /// The context limit the capped fixture's budget declares. Large enough that
    /// a scripted turn never reaches the fold trigger, so the capped run opens
    /// no compaction of its own.
    private static let cappedBudgetLimit = 4_096

    /// The tool-output token cap the capped fixture's budget declares, small
    /// enough that a marker output is really truncated.
    private static let cappedToolOutputLimit = 1

    /// What ``ToolOutputCapping/capped(text:toTokenLimit:)`` stamps into a
    /// truncated output. The capped test matches on it, so a budget that never
    /// reached the mount would fail rather than pass on a span count alone.
    private static let truncationMarker = "[truncated:"

    // MARK: - Fixture tools

    /// A `FoundationModels.Tool` that declares ``ToolMount/Mode/background`` for
    /// itself and returns at once, so a scripted turn reaches
    /// ``BackgroundToolRunner`` and its run settles without a wall clock.
    private final class BackgroundMarkerTool: Tool, BackgroundTool, Sendable {
        /// The model-facing tool name a scripted call names to reach this tool.
        static let toolName = "marker-background"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = BackgroundMarkerTool.toolName

        /// The `Tool` description requirement. The scripted model picks its call
        /// by name and never reads this, but the SDK renders it into the tool
        /// definition it puts in the transcript.
        let description = "test-only tool that declares the background mount and returns at once"

        /// The mount this tool declares for itself, which wins over the
        /// session's own configuration.
        var mount: ToolMount? { ToolMount(mode: .background, timeout: nil) }

        /// Returns the named step's marker with no delay.
        ///
        /// - Parameter arguments: The call's decoded arguments; `value` is the
        ///   step name.
        /// - Returns: ``ScriptedToolFixture/marker(for:)`` for the named step.
        /// - Throws: Never — the tool cannot fail; `throws` comes from the
        ///   `Tool` requirement.
        func call(arguments: AmbientToolArguments) async throws -> String {
            ScriptedToolFixture.marker(for: arguments.value)
        }
    }

    // MARK: - Helpers

    /// One scripted round asking for one call on `toolName`, naming `step`.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool to call.
    ///   - step: The `value` argument the call names.
    /// - Returns: The one-round script.
    private static func script(callingTool toolName: String, naming step: String) -> ScriptedTurnScript
    {
        ScriptedTurnScript(
            rounds: [[ScriptedToolCall(id: "call-1", toolName: toolName, argument: .literal(step))]])
    }

    /// Every finished span of `name` the driven work reported.
    ///
    /// Filtered by name rather than counted over the whole tracer: the fixture's
    /// own ``Router/resolve(profile:reporting:)`` reports to the same tracer,
    /// and it opens a resolve span with one load span under it for each slot.
    ///
    /// - Parameters:
    ///   - name: The operation name to keep.
    ///   - tracer: The tracer the driven work reported to.
    /// - Returns: The matching finished spans, in finish order.
    private static func spans(named name: String, in tracer: InMemoryTracer) -> [FinishedInMemorySpan]
    {
        tracer.finishedSpans.filter { $0.operationName == name }
    }

    /// The single tool span a one-call turn opened.
    ///
    /// - Parameter tracer: The tracer the turn reported to.
    /// - Returns: The single finished tool span.
    /// - Throws: When the tracer holds no tool span, or more than one.
    private static func singleToolSpan(reportedTo tracer: InMemoryTracer) throws
        -> FinishedInMemorySpan
    {
        let spans = spans(named: toolSpanName, in: tracer)
        try #require(spans.count == 1)
        return try #require(spans.first)
    }

    /// Awaits every background run the session tracked, so a suite leaves no run
    /// in flight behind it.
    ///
    /// - Parameter session: The session whose mailbox tracked the runs.
    private static func settleBackgroundRuns(of session: RoutedSession) async {
        for run in await session.mailbox.backgroundRuns() {
            _ = await session.mailbox.wait(
                completionToken: run.completionToken, seconds: MountFixtures.settlementDeadline)
        }
    }

    // MARK: - One span for each call, under the turn

    @Test("a turn with two tool calls opens one turn span and two tool spans, each a child of it")
    func twoCallsOpenTwoToolSpansUnderOneTurnSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName)),
                    ScriptedToolCall(
                        id: "call-2",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(Self.secondStepName)),
                ]
            ]),
            mounting: [MarkerEmittingTool()],
            tempDirPrefix: "ToolTracingTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let turnSpans = Self.spans(named: Self.turnSpanName, in: tracer)
        try #require(turnSpans.count == 1)
        let turnSpan = try #require(turnSpans.first)
        let toolSpans = Self.spans(named: Self.toolSpanName, in: tracer)
        #expect(toolSpans.count == 2)
        #expect(toolSpans.allSatisfy { $0.parentSpanID == turnSpan.spanID })
    }

    @Test("a foreground tool span is internal and carries the documented attributes")
    func foregroundToolSpanCarriesItsAttributes() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.script(
                callingTool: MarkerEmittingTool.toolName, naming: ScriptedToolFixture.firstStepName),
            mounting: [MarkerEmittingTool()],
            tempDirPrefix: "ToolTracingTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let span = try Self.singleToolSpan(reportedTo: tracer)
        #expect(span.kind == .internal)
        #expect(span.attributes.get("tool.name") == .string(MarkerEmittingTool.toolName))
        #expect(span.attributes.get("session.id") == .string(fixture.session.id.description))
        #expect(span.attributes.get("tool.run_kind") == .string("foreground"))
        #expect(span.attributes.get("tool.outcome") == .string("succeeded"))
        #expect(span.errors.isEmpty)
    }

    // MARK: - The call that fails

    @Test("a tool call that throws keeps its span, with the error recorded")
    func failedToolCallRecordsItsErrorOnTheSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.script(
                callingTool: ThrowingMarkerTool.toolName, naming: ScriptedToolFixture.firstStepName),
            mounting: [ThrowingMarkerTool()],
            tempDirPrefix: "ToolTracingTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        await #expect(throws: (any Error).self) {
            _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        }

        let span = try Self.singleToolSpan(reportedTo: tracer)
        #expect(span.errors.count == 1)
        #expect(span.attributes.get("tool.outcome") == .string("failed"))
    }

    // MARK: - The background mount

    @Test("a background tool's span covers the launch step and names the background run kind")
    func backgroundToolSpanNamesItsRunKind() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.script(
                callingTool: BackgroundMarkerTool.toolName,
                naming: ScriptedToolFixture.firstStepName),
            mounting: [BackgroundMarkerTool()],
            tempDirPrefix: "ToolTracingTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        await Self.settleBackgroundRuns(of: fixture.session)

        let span = try Self.singleToolSpan(reportedTo: tracer)
        #expect(span.attributes.get("tool.name") == .string(BackgroundMarkerTool.toolName))
        #expect(span.attributes.get("tool.run_kind") == .string("background"))
        #expect(span.errors.isEmpty)
    }

    // MARK: - The binding-only mount

    @Test("a non-String-output tool opens its own tool span through the binding-only decorator")
    func nonStringOutputToolOpensItsOwnSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.script(
                callingTool: NonStringMarkerTool.toolName,
                naming: ScriptedToolFixture.firstStepName),
            mounting: [NonStringMarkerTool()],
            tempDirPrefix: "ToolTracingTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        let span = try Self.singleToolSpan(reportedTo: tracer)
        #expect(span.attributes.get("tool.name") == .string(NonStringMarkerTool.toolName))
        #expect(span.attributes.get("tool.run_kind") == .string("foreground"))
        #expect(span.attributes.get("tool.outcome") == .string("succeeded"))
    }

    // MARK: - The capping layer opens no span of its own

    @Test("a tool with an output token cap configured still opens exactly one tool span")
    func aCappedToolOpensExactlyOneSpan() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.script(
                callingTool: MarkerEmittingTool.toolName, naming: ScriptedToolFixture.firstStepName),
            mounting: [MarkerEmittingTool()],
            tempDirPrefix: "ToolTracingTests",
            budget: TokenBudget(
                limit: Self.cappedBudgetLimit, toolOutputLimit: Self.cappedToolOutputLimit),
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        // The capping layer really stands over the mount: the output the model
        // read back was truncated. Without this the span count below would pass
        // just as well on a session that was never capped at all.
        #expect(answer.contains(Self.truncationMarker))
        #expect(Self.spans(named: Self.toolSpanName, in: tracer).count == 1)
    }
}
