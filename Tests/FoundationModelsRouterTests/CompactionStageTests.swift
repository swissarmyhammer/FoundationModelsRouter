import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task vvjfkfb (compaction epic — compaction_plan.md §1.3): the two
/// deterministic, pure compaction stages — ``ToolOutputElision`` and
/// ``TurnTruncation`` — against fixture transcripts covering every §1.3
/// invariant plus turn-boundary edge cases.
///
/// A "turn" (``TranscriptTurns``) is a `.prompt` entry plus everything up to
/// the next `.prompt`: optionally a `.toolCalls`/`.toolOutput` pair, and a
/// `.response`. Every fixture below prefixes turns with a single
/// `.instructions` entry — the header that must never be touched.
@Suite("Compaction stages: ToolOutputElision and TurnTruncation")
struct CompactionStageTests {
    // MARK: - Fixtures
    //
    // makeInstructions()/makeTurn()/makeTurns() live in
    // TranscriptFixtures (Helpers/TranscriptTestHelpers.swift), shared with
    // CompactorPipelineTests.

    // MARK: - Instructions invariant

    @Test("ToolOutputElision never modifies or drops the instructions entry")
    func toolOutputElisionPreservesInstructions() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = ToolOutputElision(keepRecentTurns: 4).apply(transcript)

        #expect(Array(result).first == instructions)
    }

    @Test("TurnTruncation never modifies or drops the instructions entry")
    func turnTruncationPreservesInstructions() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = TurnTruncation(keepRecentTurns: 4).apply(transcript)

        #expect(Array(result).first == instructions)
    }

    // MARK: - Tool pair preservation / elision

    @Test("ToolOutputElision keeps an old turn's toolCalls entry unchanged while shrinking its toolOutput payload")
    func toolOutputElisionPreservesToolCallsAndShrinksToolOutput() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigOutput = String(repeating: "large tool result content ", count: 200)
        let turns = try TranscriptFixtures.makeTurns(6, toolOutputText: bigOutput)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = Array(ToolOutputElision(keepRecentTurns: 4).apply(transcript))

        // Turn 1 is old (only turns 3...6 are the 4-turn recency window);
        // its toolCalls entry survives byte-identical.
        let originalToolCalls1 = turns[0][1]
        #expect(result.contains(originalToolCalls1))

        guard case .toolOutput(let elided) = result.first(where: { $0.id == "toolOutput-1" })! else {
            Issue.record("expected an elided .toolOutput entry with id toolOutput-1")
            return
        }
        #expect(elided.toolName == "search")
        #expect(
            !elided.segments.contains { segment in
                if case .text(let text) = segment { return text.content == bigOutput }
                return false
            })
    }

    @Test("elision placeholder names the tool and is a short one-line message")
    func elisionPlaceholderContent() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigOutput = String(repeating: "x", count: 5000)
        let turns = try TranscriptFixtures.makeTurns(6, toolOutputText: bigOutput)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = Array(ToolOutputElision(keepRecentTurns: 4).apply(transcript))
        guard case .toolOutput(let elided) = result.first(where: { $0.id == "toolOutput-1" })!,
            case .text(let text) = elided.segments.first!
        else {
            Issue.record("expected the elided toolOutput to carry a single text segment")
            return
        }

        #expect(text.content.contains("search"))
        #expect(!text.content.contains("x"))
        #expect(text.content.count < 200)
    }

    @Test("TurnTruncation drops an old turn's toolCalls/toolOutput pair together, orphaning neither")
    func turnTruncationDropsToolPairTogether() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = Array(TurnTruncation(keepRecentTurns: 4).apply(transcript))
        let ids = Set(result.map(\.id))

        // Turns 1 and 2 (the two oldest of 6, keeping the newest 4) are
        // dropped entirely: neither their toolCalls nor toolOutput remain.
        #expect(!ids.contains("calls-1"))
        #expect(!ids.contains("toolOutput-1"))
        #expect(!ids.contains("calls-2"))
        #expect(!ids.contains("toolOutput-2"))
        // The retained turns' pairs are both present.
        #expect(ids.contains("calls-3"))
        #expect(ids.contains("toolOutput-3"))
    }

    // MARK: - Recency window survives verbatim

    @Test("ToolOutputElision leaves the recency window byte-identical")
    func toolOutputElisionRecencyWindowVerbatim() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6, toolOutputText: String(repeating: "y", count: 500))
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = Array(ToolOutputElision(keepRecentTurns: 4).apply(transcript))
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }

        #expect(Array(result.suffix(expectedRecentTail.count)) == expectedRecentTail)
    }

    @Test("TurnTruncation leaves the recency window byte-identical")
    func turnTruncationRecencyWindowVerbatim() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let result = Array(TurnTruncation(keepRecentTurns: 4).apply(transcript))
        let expectedRecentTail = turns.suffix(4).flatMap { $0 }

        #expect(Array(result.suffix(expectedRecentTail.count)) == expectedRecentTail)
        #expect(result.count == 1 + expectedRecentTail.count)  // instructions + 4 turns
    }

    // MARK: - Turn-boundary edge cases

    @Test("a tool pair exactly at the recency window edge stays fully on its own side, never split")
    func toolPairAtWindowEdgeNeverSplit() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        // Exactly keepRecentTurns + 1 turns: turn 1 is the single old turn,
        // turns 2-5 are the recency window.
        let turns = try TranscriptFixtures.makeTurns(5)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let elided = Array(ToolOutputElision(keepRecentTurns: 4).apply(transcript))
        // Turn 1 (old): toolCalls survives, toolOutput is elided.
        #expect(elided.contains(turns[0][1]))
        #expect(!elided.contains(turns[0][2]))
        // Turn 2 (first of the recency window): both entries untouched.
        #expect(elided.contains(turns[1][1]))
        #expect(elided.contains(turns[1][2]))

        let truncated = Array(TurnTruncation(keepRecentTurns: 4).apply(transcript))
        // Turn 1 (old) is dropped entirely.
        #expect(!truncated.contains(turns[0][1]))
        #expect(!truncated.contains(turns[0][2]))
        // Turn 2 (recent) survives entirely, tool pair intact.
        #expect(truncated.contains(turns[1][1]))
        #expect(truncated.contains(turns[1][2]))
    }

    @Test("a transcript with only instructions has no turns to fold; both stages no-op")
    func onlyInstructionsIsNoOp() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let transcript = Transcript(entries: [instructions])

        #expect(ToolOutputElision().apply(transcript) == transcript)
        #expect(TurnTruncation().apply(transcript) == transcript)
    }

    @Test("fewer turns than keepRecentTurns means every turn is in the recency window; both stages no-op")
    func fewerTurnsThanWindowIsNoOp() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(2, toolOutputText: String(repeating: "z", count: 500))
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        #expect(ToolOutputElision(keepRecentTurns: 4).apply(transcript) == transcript)
        #expect(TurnTruncation(keepRecentTurns: 4).apply(transcript) == transcript)
    }

    @Test("keepRecentTurns of 0 or fewer protects nothing: every turn is eligible for folding")
    func nonPositiveKeepRecentTurnsProtectsNoTurns() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let bigOutput = String(repeating: "v", count: 500)
        let turns = try TranscriptFixtures.makeTurns(3, toolOutputText: bigOutput)
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let elided = Array(ToolOutputElision(keepRecentTurns: 0).apply(transcript))
        // Every turn's toolOutput is elided, including the newest.
        #expect(!elided.contains(turns[0][2]))
        #expect(!elided.contains(turns[1][2]))
        #expect(!elided.contains(turns[2][2]))

        let truncated = Array(TurnTruncation(keepRecentTurns: 0).apply(transcript))
        // Every turn is dropped entirely; only the header (instructions) remains.
        #expect(truncated == [instructions])
    }

    // MARK: - Purity

    @Test("both stages are pure: the same input always yields the same output")
    func stagesArePure() throws {
        let instructions = TranscriptFixtures.makeInstructions()
        let turns = try TranscriptFixtures.makeTurns(6, toolOutputText: String(repeating: "w", count: 500))
        let transcript = Transcript(entries: [instructions] + turns.flatMap { $0 })

        let elision = ToolOutputElision(keepRecentTurns: 4)
        #expect(elision.apply(transcript) == elision.apply(transcript))

        let truncation = TurnTruncation(keepRecentTurns: 4)
        #expect(truncation.apply(transcript) == truncation.apply(transcript))
    }
}
