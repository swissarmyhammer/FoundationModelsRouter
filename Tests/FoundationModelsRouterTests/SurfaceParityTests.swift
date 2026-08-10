import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Everything one scripted turn was observed to do, gathered the same way
/// whichever `RoutedSession` surface drove it.
///
/// Every field is content the turn produced or a count of work the turn did.
/// None of them is a count of stream events: a turn where every call was
/// announced and none failed can still leave the model uninformed (task
/// ^cvtfem3), so only ``deliveredToolOutputs`` and ``answer`` are allowed to
/// stand for delivery.
struct SurfaceTurnOutcome: Equatable {
    /// The turn's final answer text.
    let answer: String

    /// The tool calls the answering generation found in its transcript, in
    /// order.
    let requestedCalls: [ScriptedCallRecord]

    /// The tool output texts the answering generation read back, in order.
    let deliveredToolOutputs: [String]

    /// How many times the model was asked to generate.
    let modelTurnCount: Int

    /// How many mounted tool bodies actually ran, across every mounted tool.
    let toolExecutionCount: Int

    /// The normalized description of the error the surface threw, or `nil` when
    /// the turn completed. See
    /// ``SurfaceParityTests/failureDescription(of:)`` for what is kept.
    let failureDescription: String?
}

/// One turn shape the parity harness holds both session surfaces to.
struct SurfaceParityRow: Sendable, CustomTestStringConvertible {
    /// The shape's name, which also names the case in test output.
    let name: String

    /// The turn shape the scripted model plays out.
    let script: ScriptedTurnScript

    /// Builds a fresh set of tools to mount — called once per surface, so
    /// neither surface reads the other's call log.
    let makeTools: @Sendable () -> [any MarkerRecordingTool]

    /// The final answer text both surfaces must produce.
    let expectedAnswer: String

    /// The calls both surfaces must be observed to have made, in order.
    let expectedCalls: [ScriptedCallRecord]

    /// The tool outputs both surfaces must deliver into the answering
    /// generation, in order.
    let expectedDeliveredToolOutputs: [String]

    /// The normalized description of the error both surfaces must end with, or
    /// `nil` when the turn must complete.
    let expectedFailureDescription: String?

    /// The number of model turns the shape takes: one generation per scripted
    /// round, plus the one that answers — unless the turn aborts, in which case
    /// the answering generation never runs.
    var expectedModelTurnCount: Int {
        expectedFailureDescription == nil ? script.rounds.count + 1 : script.rounds.count
    }

    /// How many tool bodies the shape runs: one per scripted call.
    var expectedToolExecutionCount: Int { script.rounds.reduce(0) { $0 + $1.count } }

    /// The whole outcome both surfaces must produce.
    var expectedOutcome: SurfaceTurnOutcome {
        SurfaceTurnOutcome(
            answer: expectedAnswer,
            requestedCalls: expectedCalls,
            deliveredToolOutputs: expectedDeliveredToolOutputs,
            modelTurnCount: expectedModelTurnCount,
            toolExecutionCount: expectedToolExecutionCount,
            failureDescription: expectedFailureDescription)
    }

    /// The name this shape is reported under in test output.
    var testDescription: String { name }
}

/// Task ^vhjhaey: holds `RoutedSession`'s two generation surfaces —
/// `respond(to:)` and `streamEvents(to:)` — to one observable outcome on a
/// tool-using turn.
///
/// Every Router feature a host wants arrives by moving that host off a plain
/// `LanguageModelSession` and onto a `RoutedSession`. That move has to be
/// behaviour-preserving for the ordinary case, and it has to be the same on
/// both surfaces, or a host picks up a defect by choosing how it reads its
/// output. Task ^cvtfem3 fixed one such defect; this suite is the guard that
/// stops the next one taking a different shape.
///
/// The suite is table-driven: one row per turn shape, and one new row covers a
/// new case rather than a new test. Each row is asserted twice — the two
/// surfaces against each other, and each of them against the outcome the row
/// states — so a shape that breaks identically on both surfaces still fails.
@Suite("respond(to:) and streamEvents(to:) behave identically on a tool-using turn")
struct SurfaceParityTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SurfaceParityTests"

    /// The step names the harness's calls use, named once so a row's script,
    /// its expected calls, and its expected outputs cannot drift apart.
    private enum Step {
        /// The step the first call of every multi-call shape names.
        static let first = "ONE"

        /// The step a shape's second, independent call names.
        static let second = "TWO"

        /// The step the failing shape's call names.
        static let failing = "BOOM"
    }

    /// The model-facing names the independent-calls shape mounts its two tools
    /// under, so its two calls in one round are told apart by tool as well as
    /// by argument.
    private enum IndependentTool {
        /// The tool the round's first call names.
        static let first = "marker-independent-a"

        /// The tool the round's second call names.
        static let second = "marker-independent-b"
    }

    /// The position of the turn's first tool output in the transcript — where a
    /// chained call reads its argument from.
    private static let firstOutputIndex = 0

    /// The tool output a call naming ``Step/first`` produces.
    private static let firstOutput = ScriptedToolFixture.marker(for: Step.first)

    /// The tool output the chained shape's second call produces: a marker over
    /// the first call's own output, so this text exists only when that output
    /// really reached the model.
    private static let chainedOutput = ScriptedToolFixture.marker(for: firstOutput)

    /// The tool output a call naming ``Step/second`` produces.
    private static let secondOutput = ScriptedToolFixture.marker(for: Step.second)

    /// The failure both surfaces must end the throwing shape with: the failing
    /// tool's name and the error its body raised, as
    /// ``failureDescription(of:)`` renders them.
    private static let expectedFailure =
        "\(ThrowingMarkerTool.toolName): \(ThrowingMarkerTool.CallFailure(step: Step.failing))"

    /// The stable text a thrown turn is compared by: the failing tool's name
    /// and the error its body raised.
    ///
    /// The SDK wraps a tool failure in a `LanguageModelSession.ToolCallError`
    /// whose printed form carries the whole mounted decorator chain, including
    /// the owning session's own ULID. That ULID is different in every run, so
    /// comparing the raw text would report a divergence between two runs of the
    /// same shape and never report a real one.
    ///
    /// - Parameter error: The error a surface threw.
    /// - Returns: The tool name and underlying error for a tool-call failure;
    ///   the error's own printed form for anything else.
    private static func failureDescription(of error: any Error) -> String {
        guard let toolCallError = error as? LanguageModelSession.ToolCallError else {
            return String(describing: error)
        }
        return "\(toolCallError.tool.name): \(toolCallError.underlyingError)"
    }

    /// Builds one scripted call on `toolName` with a fixed `step` argument.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool to call.
    ///   - step: The `value` argument to call with.
    /// - Returns: The scripted call.
    private static func call(on toolName: String, naming step: String) -> ScriptedToolCall {
        ScriptedToolCall(
            id: "\(toolName)-\(step)", toolName: toolName, argument: .literal(step))
    }

    /// Builds one scripted call on `toolName` whose argument is the tool output
    /// at `index` — the shape that only produces its argument when an earlier
    /// output really reached the model.
    ///
    /// - Parameters:
    ///   - toolName: The model-facing name of the tool to call.
    ///   - index: The position of the earlier tool output to call with.
    /// - Returns: The scripted call.
    private static func call(on toolName: String, readingOutput index: Int) -> ScriptedToolCall {
        ScriptedToolCall(
            id: "\(toolName)-from-output-\(index)", toolName: toolName,
            argument: .priorToolOutput(index: index))
    }

    /// The turn shapes both surfaces are held to.
    static let rows: [SurfaceParityRow] = [
        SurfaceParityRow(
            name: "one call, one output, answer",
            script: ScriptedTurnScript(
                rounds: [[call(on: MarkerEmittingTool.toolName, naming: Step.first)]]),
            makeTools: { [MarkerEmittingTool()] },
            expectedAnswer: ScriptedToolFixture.answerPrefix + firstOutput,
            expectedCalls: [
                ScriptedCallRecord(
                    toolName: MarkerEmittingTool.toolName, argumentValue: Step.first)
            ],
            expectedDeliveredToolOutputs: [firstOutput],
            expectedFailureDescription: nil),

        SurfaceParityRow(
            name: "two sequential calls, each output feeding the next",
            script: ScriptedTurnScript(
                rounds: [
                    [call(on: MarkerEmittingTool.toolName, naming: Step.first)],
                    [call(on: MarkerEmittingTool.toolName, readingOutput: firstOutputIndex)],
                ]),
            makeTools: { [MarkerEmittingTool()] },
            expectedAnswer: ScriptedToolFixture.answerPrefix
                + [firstOutput, chainedOutput].joined(separator: ScriptedToolFixture.answerSeparator),
            expectedCalls: [
                ScriptedCallRecord(
                    toolName: MarkerEmittingTool.toolName, argumentValue: Step.first),
                ScriptedCallRecord(
                    toolName: MarkerEmittingTool.toolName, argumentValue: firstOutput),
            ],
            expectedDeliveredToolOutputs: [firstOutput, chainedOutput],
            expectedFailureDescription: nil),

        SurfaceParityRow(
            name: "two independent calls in one turn",
            script: ScriptedTurnScript(
                rounds: [
                    [
                        call(on: IndependentTool.first, naming: Step.first),
                        call(on: IndependentTool.second, naming: Step.second),
                    ]
                ]),
            makeTools: {
                [
                    MarkerEmittingTool(name: IndependentTool.first),
                    MarkerEmittingTool(name: IndependentTool.second),
                ]
            },
            expectedAnswer: ScriptedToolFixture.answerPrefix
                + [firstOutput, secondOutput].joined(separator: ScriptedToolFixture.answerSeparator),
            expectedCalls: [
                ScriptedCallRecord(toolName: IndependentTool.first, argumentValue: Step.first),
                ScriptedCallRecord(toolName: IndependentTool.second, argumentValue: Step.second),
            ],
            expectedDeliveredToolOutputs: [firstOutput, secondOutput],
            expectedFailureDescription: nil),

        // The failing shape does NOT feed the error back into generation. The
        // SDK aborts the turn at the failed call and raises the failure to the
        // caller, so there is no answering generation, no answer text, and no
        // delivered output — and both surfaces do exactly that, which is the
        // parity claim this row locks. What proves the call really ran is
        // `toolExecutionCount` plus the failure text, which names the tool and
        // the step it was called with.
        SurfaceParityRow(
            name: "a call that throws",
            script: ScriptedTurnScript(
                rounds: [[call(on: ThrowingMarkerTool.toolName, naming: Step.failing)]]),
            makeTools: { [ThrowingMarkerTool()] },
            expectedAnswer: "",
            expectedCalls: [],
            expectedDeliveredToolOutputs: [],
            expectedFailureDescription: expectedFailure),

        SurfaceParityRow(
            name: "a tool with non-String output",
            script: ScriptedTurnScript(
                rounds: [[call(on: NonStringMarkerTool.toolName, naming: Step.first)]]),
            makeTools: { [NonStringMarkerTool()] },
            expectedAnswer: ScriptedToolFixture.answerPrefix + firstOutput,
            expectedCalls: [
                ScriptedCallRecord(
                    toolName: NonStringMarkerTool.toolName, argumentValue: Step.first)
            ],
            expectedDeliveredToolOutputs: [firstOutput],
            expectedFailureDescription: nil),

        // A tool is still mounted here, so this shape also says that mounting
        // one does not by itself put a call, an output, or an extra model turn
        // into a turn that asked for none.
        SurfaceParityRow(
            name: "no calls at all",
            script: ScriptedTurnScript(rounds: []),
            makeTools: { [MarkerEmittingTool()] },
            expectedAnswer: ScriptedToolFixture.answerPrefix
                + ScriptedToolFixture.noToolOutputsMarker,
            expectedCalls: [],
            expectedDeliveredToolOutputs: [],
            expectedFailureDescription: nil),
    ]

    /// Drives one turn for `row` and gathers what it did.
    ///
    /// - Parameters:
    ///   - row: The turn shape to play out.
    ///   - answering: How this surface produces the turn's answer text from the
    ///     vended session — the one thing the two surfaces do differently.
    /// - Returns: The turn's observed outcome.
    /// - Throws: Whatever building the session throws. A failure raised by the
    ///   turn itself is captured into the outcome instead, so a surface that
    ///   throws can be compared against one that does not.
    private static func runTurn(
        _ row: SurfaceParityRow,
        answering: (RoutedSession) async throws -> String
    ) async throws -> SurfaceTurnOutcome {
        let tools = row.makeTools()
        let fixture = try await ScriptedSessionFixture.make(
            playing: row.script,
            mounting: tools.map { $0 as any Tool },
            tempDirPrefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var answer = ""
        var failureDescription: String?
        do {
            answer = try await answering(fixture.session)
        } catch {
            failureDescription = Self.failureDescription(of: error)
        }
        return SurfaceTurnOutcome(
            answer: answer,
            requestedCalls: fixture.log.requestedCalls,
            deliveredToolOutputs: fixture.log.deliveredToolOutputs,
            modelTurnCount: fixture.log.modelTurnCount,
            toolExecutionCount: tools.reduce(0) { $0 + $1.calledSteps.count },
            failureDescription: failureDescription)
    }

    /// Concatenates the text a `streamEvents(to:)` turn yields, ignoring every
    /// other event: an event's presence is not evidence of delivery, only the
    /// text is.
    ///
    /// - Parameter session: The session to stream a turn on.
    /// - Returns: The turn's answer text.
    /// - Throws: Whatever the stream throws.
    private static func streamedAnswer(from session: RoutedSession) async throws -> String {
        var answer = ""
        for try await event in await session.streamEvents(to: ScriptedToolFixture.prompt) {
            guard case .textDelta(let delta) = event else { continue }
            answer += delta
        }
        return answer
    }

    @Test("both surfaces produce the same observable outcome", arguments: rows)
    func surfacesAgreeOnOneToolUsingTurn(_ row: SurfaceParityRow) async throws {
        let responded = try await Self.runTurn(row) {
            try await $0.respond(to: ScriptedToolFixture.prompt)
        }
        let streamed = try await Self.runTurn(row) { try await Self.streamedAnswer(from: $0) }

        #expect(
            responded == streamed,
            "the two surfaces diverged on \(row.name): respond \(responded), stream \(streamed)")
        #expect(responded == row.expectedOutcome, "respond(to:) on \(row.name)")
        #expect(streamed == row.expectedOutcome, "streamEvents(to:) on \(row.name)")
    }
}
