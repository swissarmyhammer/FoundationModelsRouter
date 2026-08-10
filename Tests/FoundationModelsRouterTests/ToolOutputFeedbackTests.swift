import Foundation
import Testing

@testable import FoundationModelsRouter

/// Task ^cvtfem3: pins the claim a `RoutedSession` turn is supposed to make —
/// **a mounted tool's output reaches the model's next generation** — on both of
/// the session's generation surfaces, `respond(to:)` and `streamEvents(to:)`.
///
/// Both tests drive the same scripted multi-call turn against the same mounted
/// tool and assert the same thing about the answer, by content: it carries the
/// marker text of *every* tool output the turn produced. Holding the two
/// surfaces to one assertion is the point — a surface that drops tool output,
/// or a loop that delivers only the first output, fails here while the other
/// surface passes, and the difference is the defect.
@Suite("Mounted tool output reaches the model's next generation")
struct ToolOutputFeedbackTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "ToolOutputFeedbackTests"

    /// The steps one turn calls the mounted tool for, in order. Two of them, so
    /// a turn is `call -> output -> call again -> output -> answer` and a loop
    /// that delivers only the first output is caught.
    private static let steps = ["ONE", "TWO"]

    /// The marker each step's tool output carries, in step order.
    private static var markers: [String] { steps.map { ScriptedToolFixture.marker(for: $0) } }

    /// The turn shape: one round per step, each round asking for a single call
    /// on the mounted tool with that step as its argument.
    private static var script: ScriptedTurnScript {
        ScriptedTurnScript(
            rounds: steps.map { step in
                [
                    ScriptedToolCall(
                        id: "scripted-tool-call-\(step)",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(step))
                ]
            })
    }

    /// Builds a fresh `RoutedSession` over the two-step script, with one
    /// ``MarkerEmittingTool`` mounted.
    ///
    /// - Returns: The vended session fixture and the mounted tool instance.
    /// - Throws: Whatever profile resolution throws.
    private static func makeSession() async throws -> (
        fixture: ScriptedSessionFixture, tool: MarkerEmittingTool
    ) {
        let tool = MarkerEmittingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: script, mounting: [tool], tempDirPrefix: tempDirPrefix)
        return (fixture, tool)
    }

    /// Asserts the one contract both surfaces are held to: the turn really made
    /// a call per step, and the answer carries every tool output's marker.
    ///
    /// - Parameters:
    ///   - answer: The turn's final answer text.
    ///   - tool: The mounted tool the turn called.
    private static func expectEveryToolOutputReachedTheAnswer(
        _ answer: String, tool: MarkerEmittingTool
    ) {
        // The turn is genuinely multi-call: one tool call per step, in order.
        #expect(tool.calledSteps == steps)
        // And every one of those outputs reached the generation that answered.
        for marker in markers {
            #expect(answer.contains(marker), "answer did not carry \(marker): \(answer)")
        }
    }

    @Test("respond(to:) answers with every mounted tool output the turn produced")
    func respondFeedsToolOutputBackIntoGeneration() async throws {
        let (fixture, tool) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        Self.expectEveryToolOutputReachedTheAnswer(answer, tool: tool)
    }

    @Test("streamEvents(to:) answers with every mounted tool output the turn produced")
    func streamEventsFeedsToolOutputBackIntoGeneration() async throws {
        let (fixture, tool) = try await Self.makeSession()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var answer = ""
        let events = await fixture.session.streamEvents(to: ScriptedToolFixture.prompt)
        for try await event in events {
            guard case .textDelta(let delta) = event else { continue }
            answer += delta
        }

        Self.expectEveryToolOutputReachedTheAnswer(answer, tool: tool)
    }
}
