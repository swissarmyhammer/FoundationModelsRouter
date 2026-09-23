import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Proves that a compaction counts the parts of the live context without a
/// chat-template render of a set that holds no user message (task ^9ax82gr).
///
/// The counter is a ``TokenizerTokenCounter`` over a
/// ``ScriptedChatTokenizer`` whose template refuses messages with no user
/// message, as the Qwen3.8 and Llama-3.2 templates do. The live context holds
/// instructions, user and assistant entries, and a protected tool output.
@Suite("Compaction part costs: no template render of a set that is not a conversation")
struct CompactionPartCostTests {
    /// The summary the scripted summarizer writes.
    private static let summary = "short summary"

    /// A counter whose template refuses messages with no user message.
    ///
    /// - Returns: The counter.
    private static func strictCounter() -> TokenizerTokenCounter {
        TokenizerTokenCounter(tokenizer: ScriptedChatTokenizer(requiresUserMessage: true))
    }

    /// The instructions entries of `entries`, in order.
    ///
    /// - Parameter entries: The entries to read.
    /// - Returns: The instructions entries.
    private static func instructions(of entries: [Transcript.Entry]) -> [Transcript.Entry] {
        entries.filter {
            if case .instructions = $0 { return true }
            return false
        }
    }

    /// The protected tool output and the call that made it: the entries the
    /// snapshot keeps word for word.
    ///
    /// - Returns: The kept entries, in order.
    /// - Throws: What the fixture builders throw.
    private static func keptEntries() throws -> [Transcript.Entry] {
        [try ProtectedToolOutputFixtures.skillCallsEntry(), ProtectedToolOutputFixtures.skillOutputEntry]
    }

    /// Compacts the protected-output fixture with `counter`, with a target
    /// one token under the size of the live context.
    ///
    /// - Parameter counter: The counter every size is measured with.
    /// - Returns: The live context, the compacted context, and the result.
    /// - Throws: What the compaction throws.
    private static func compactFixture(
        counter: TokenizerTokenCounter
    ) async throws -> (live: Transcript, compacted: Transcript, result: CompactionResult) {
        let live = try ProtectedToolOutputFixtures.transcript()
        let before = try counter.count(live)
        let budget = TokenBudget(limit: before, target: Double(before - 1) / Double(before))
        let (compacted, result) = try await Compactor.compact(
            live, prompt: .default, budget: budget, counter: counter,
            summarizers: [unboundedOwnModelSlot(RecordingSummarizer(summary: summary))], pendingRuns: [],
            protection: ProtectedToolOutputFixtures.rule)
        return (live, compacted, result)
    }

    @Test("the scripted template refuses the instructions alone, as the Qwen3.8 template does")
    func templateRefusesInstructionsAlone() throws {
        let entries = Array(try ProtectedToolOutputFixtures.transcript())

        #expect(throws: ScriptedChatTokenizer.TemplateError.noUserMessage) {
            _ = try Self.strictCounter().count(Transcript(entries: Self.instructions(of: entries)))
        }
    }

    @Test("a compaction over instructions, user and assistant entries and a protected tool output runs with no error")
    func compactionRunsWithNoTemplateError() async throws {
        let (_, compacted, result) = try await Self.compactFixture(counter: Self.strictCounter())

        #expect(result.shortfall == nil)
        #expect(result.summary == Self.summary)
        #expect(result.tokensAfter < result.tokensBefore)
        let summaryEntryId = try #require(result.summaryEntryId)
        #expect(Array(compacted).map(\.id).contains(summaryEntryId))
        #expect(Array(Array(compacted).suffix(2)) == (try Self.keptEntries()))
    }

    @Test("the protected cost is the whole less the whole without the protected entries")
    func protectedCostIsTheDifferenceInsideTheWhole() async throws {
        let counter = Self.strictCounter()
        let (live, _, result) = try await Self.compactFixture(counter: counter)

        let keptIds = Set(try Self.keptEntries().map(\.id))
        let withoutKept = Array(live).filter { !keptIds.contains($0.id) }
        let expected = try counter.count(live) - (try counter.count(Transcript(entries: withoutKept)))
        #expect(result.protectedTokens == expected)
    }

    @Test("the part costs sum to the whole's cost where the parts are disjoint")
    func disjointPartCostsSumToTheWhole() throws {
        let counter = Self.strictCounter()
        let whole = Array(try ProtectedToolOutputFixtures.transcript())
        let wholeTokens = try counter.count(Transcript(entries: whole))
        let instructions = Self.instructions(of: whole)
        let kept = try Self.keptEntries()
        let partIds = Set((instructions + kept).map(\.id))
        let rest = whole.filter { !partIds.contains($0.id) }

        let instructionsCost = try Summarization.cost(
            of: instructions, in: whole, wholeTokens: wholeTokens, counter: counter)
        let keptCost = try Summarization.cost(of: kept, in: whole, wholeTokens: wholeTokens, counter: counter)
        let bothCost = try Summarization.cost(
            of: instructions + kept, in: whole, wholeTokens: wholeTokens, counter: counter)

        #expect(instructionsCost + keptCost == bothCost)
        #expect(instructionsCost + keptCost + (try counter.count(Transcript(entries: rest))) == wholeTokens)
    }

    @Test("the snapshot is counted as the model receives it: with the next turn's prompt entry, whose cost comes off")
    func snapshotCountsWithTheNextTurnPrompt() async throws {
        let counter = Self.strictCounter()
        let (live, compacted, result) = try await Self.compactFixture(counter: counter)

        let standIn = Summarization.nextTurnStandIn(in: Array(live))
        #expect(standIn.count == 1)
        let conversation = Transcript(entries: Array(compacted) + standIn)
        let expected = try counter.count(conversation) - (try counter.count(Transcript(entries: standIn)))
        #expect(result.tokensAfter == expected)
    }

    @Test("the next-turn stand-in is the last prompt entry, or none when the live context holds no prompt")
    func nextTurnStandInIsTheLastPrompt() throws {
        let entries = Array(try ProtectedToolOutputFixtures.transcript())
        let lastPrompt = try #require(entries.last {
            if case .prompt = $0 { return true }
            return false
        })

        #expect(Summarization.nextTurnStandIn(in: entries) == [lastPrompt])
        #expect(Summarization.nextTurnStandIn(in: Self.instructions(of: entries)).isEmpty)
    }
}
