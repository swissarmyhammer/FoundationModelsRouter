import Foundation
import InMemoryTracing
import Testing

@testable import FoundationModelsRouter

/// The router's one standing proof of ``RouterTracing``'s safety rule: no span
/// attribute carries prompt text, response text, tool arguments, tool output,
/// or embed input text.
///
/// A finished span leaves the process through whatever backend the host
/// application bootstrapped, and the router cannot know where that backend
/// sends what it receives — so the rule is not advice, it is a contract, and
/// this suite is where the contract is measured rather than merely written
/// down.
///
/// The suite drives one session through the work that produces content: a
/// scripted turn, a tool call inside it, further turns and a fold over what
/// they accumulated, and an embed. It then reads *every* attribute of *every*
/// recorded span, and fails on any value that carries the fixture's own
/// content. Nothing here names a span, so a card that teaches the router to
/// open a new span is held to the rule the moment it lands, with no edit to
/// this file.
///
/// Card ^zgwmhd0 wrote the suite while the embed span was the only span the
/// router opened. The five cards it unblocks add the turn, tool, fold, resolve
/// and session spans, and each of them widens what this one test measures.
@Suite("No span carries the caller's content")
struct SpanContentSafetyTests {
    /// The text the embed call embeds — distinctive, so a span attribute
    /// carrying it cannot be carrying anything else.
    private static let embedInput = "embed-input-9c2e"

    /// Every attribute value of every recorded span, rendered as text and
    /// labelled by the span and key it came from.
    ///
    /// - Parameter tracer: The tracer the driven work reported to.
    /// - Returns: One entry per attribute, as `<span>.<key> = <value>`.
    private static func renderedAttributes(of tracer: InMemoryTracer) -> [String] {
        tracer.finishedSpans.flatMap { span -> [String] in
            var rendered: [String] = []
            span.attributes.forEach { key, value in
                rendered.append("\(span.operationName).\(key) = \(String(describing: value))")
            }
            return rendered
        }
    }

    @Test("no span attribute carries prompt, response, tool-output or embed-input text")
    func noSpanAttributeCarriesTheCallersContent() async throws {
        let tracer = InMemoryTracer()
        let tool = MarkerEmittingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [tool],
            tempDirPrefix: "SpanContentSafetyTests",
            tracer: tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // One turn, with one tool call inside it. The answer is composed from
        // the tool output the model read back, so it carries the marker only if
        // the output really reached generation.
        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        let toolOutput = ScriptedToolFixture.marker(for: ScriptedToolFixture.firstStepName)
        #expect(answer.contains(toolOutput))

        // Enough further turns to push the tool turn out of the un-foldable
        // recency window, so the fold below has something it may fold.
        try await driveTurns(defaultKeepRecentTurns, on: fixture.session)

        // A fold over what those turns accumulated. The budget is derived from
        // the measured pre-fold size, and the shrink says the fold really ran.
        let fold = try await fixture.session.compact(
            budget: deterministicFoldBudget(for: fixture.transcriptEntries()))
        #expect(fold.tokensAfter < fold.tokensBefore)

        // One embed, over the same profile.
        _ = try await fixture.profile.embedding.embed(texts: [Self.embedInput])

        let needles = [ScriptedToolFixture.prompt, answer, toolOutput, Self.embedInput]
        let rendered = Self.renderedAttributes(of: tracer)

        // A suite that measured nothing would pass silently, so say what was
        // measured before saying it was clean.
        #expect(!rendered.isEmpty)
        let leaks = rendered.filter { attribute in
            needles.contains { attribute.contains($0) }
        }
        #expect(leaks.isEmpty, "these span attributes carry the caller's own content: \(leaks)")
    }
}
