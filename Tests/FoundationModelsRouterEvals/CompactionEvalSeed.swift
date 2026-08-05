import Foundation
import FoundationModels

/// A built seed transcript ready to hand to the compaction pipeline: the raw
/// entries (instructions header, fact-bearing "old" turns, filler "recent"
/// turns), the fact under test, and the question probing it.
///
/// Kept separate from ``CompactionEvaluationOutcome`` (the `Codable` type
/// that actually travels through the ``Evaluations`` framework's
/// `ModelSample`/`ModelSubject`) because `Transcript.Entry` has no `Codable`
/// requirement to satisfy here — a sample only needs to carry ``id`` (see
/// ``CompactionEvaluationOutcome/seedID``), and ``CompactionEvaluation`` looks
/// the full seed back up from its own in-memory table.
struct CompactionEvalSeed: Sendable {
    /// Mirrors ``CompactionEvalFixtureSpec/id``.
    let id: String

    /// The full seed transcript: `.instructions`, then every fact-bearing
    /// "old" turn (in order), then every filler "recent" turn — in original
    /// order, exactly as ``TranscriptTurns/split(_:)`` expects.
    let entries: [Transcript.Entry]

    /// The fact ``question`` is answerable from — ``CompactionEvalFixtureSpec/facts``
    /// at ``CompactionEvalFixtureSpec/probedFactIndex``.
    let plantedFact: String

    /// Mirrors ``CompactionEvalFixtureSpec/factKeyPhrase`` — the short value
    /// `FactRetention` actually checks the answer for, since the answer can
    /// never contain the whole ``plantedFact`` sentence verbatim.
    let factKeyPhrase: String

    /// The question asked of the resumed, post-compaction session.
    let question: String

    /// Builds a seed from a hand-written fixture spec: one turn per fact
    /// (the probed fact's turn optionally delivered as a tool call/output
    /// pair instead of a plain reply — "tool traffic"), followed by
    /// `spec.recentTurnCount` filler turns drawn from
    /// ``compactionEvalFillerTurns`` (cycled if a fixture asks for more
    /// filler turns than the pool has).
    ///
    /// - Parameter spec: The fixture to build.
    /// - Returns: The assembled seed.
    static func build(from spec: CompactionEvalFixtureSpec) -> CompactionEvalSeed {
        let instructions = Transcript.Entry.instructions(
            Transcript.Instructions(
                segments: [.text(Transcript.TextSegment(content: "You are a helpful assistant in an ongoing conversation."))],
                toolDefinitions: []
            )
        )

        let factTurns: [Transcript.Entry] = spec.facts.enumerated().flatMap { index, fact -> [Transcript.Entry] in
            let deliverViaTool = spec.probedFactViaTool && index == spec.probedFactIndex
            return CompactionEvalTurn.statement(fact, viaTool: deliverViaTool)
        }

        let fillerTurns: [Transcript.Entry] = (0..<spec.recentTurnCount).flatMap { offset -> [Transcript.Entry] in
            let filler = compactionEvalFillerTurns[offset % compactionEvalFillerTurns.count]
            return CompactionEvalTurn.statement(filler, viaTool: false)
        }

        return CompactionEvalSeed(
            id: spec.id,
            entries: [instructions] + factTurns + fillerTurns,
            plantedFact: spec.facts[spec.probedFactIndex],
            factKeyPhrase: spec.factKeyPhrase,
            question: spec.question
        )
    }
}

/// Builds one ``TranscriptTurns`` turn's worth of entries for a single stated
/// fact or filler line: always starts with a `.prompt`, so
/// ``TranscriptTurns/split(_:)`` recognizes it as its own turn.
enum CompactionEvalTurn {
    /// - Parameters:
    ///   - text: The fact or filler line to state, as the turn's prompt.
    ///   - viaTool: Whether the reply is a simulated tool call + tool output
    ///     pair (agentic tool traffic) instead of a plain assistant reply.
    /// - Returns: The turn's entries, in order.
    static func statement(_ text: String, viaTool: Bool) -> [Transcript.Entry] {
        let prompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
        )
        guard viaTool else {
            let reply = Transcript.Entry.response(
                Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Noted."))])
            )
            return [prompt, reply]
        }

        let callId = "call-\(UUID().uuidString)"
        let toolCalls = Transcript.Entry.toolCalls(
            Transcript.ToolCalls(
                id: callId,
                [
                    Transcript.ToolCall(
                        id: "tc-\(UUID().uuidString)",
                        toolName: "recordFact",
                        // The literal JSON is static and known-valid.
                        arguments: try! GeneratedContent(json: #"{"text":"noted"}"#)
                    )
                ]
            )
        )
        let toolOutput = Transcript.Entry.toolOutput(
            Transcript.ToolOutput(
                id: "to-\(UUID().uuidString)",
                toolName: "recordFact",
                segments: [.text(Transcript.TextSegment(content: "recorded"))]
            )
        )
        let reply = Transcript.Entry.response(
            Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: "Noted."))])
        )
        return [prompt, toolCalls, toolOutput, reply]
    }
}
