import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// The counter every size in this test target is measured with: one token
/// per `Character`, the rule ``CharacterTokenCounter`` states. A budget a
/// test derives from this counter is in the unit the compaction measures in,
/// because each test gives the compaction this same counter.
let characterTokenCounter = CharacterTokenCounter()

/// The size, in characters, of `entries` under ``characterTokenCounter``.
///
/// The count is made entry by entry through
/// ``CharacterTokenCounter/content(of:)``, which does not throw, so a budget
/// helper can run inside a stored property's initializer. The result is equal
/// to what the counter's transcript overload counts for a transcript of the
/// same entries.
///
/// - Parameter entries: The transcript entries to count.
/// - Returns: The number of characters the model reads `entries` as.
func characterCount(of entries: [Transcript.Entry]) -> Int {
    entries.reduce(0) { $0 + characterTokenCounter.count(CharacterTokenCounter.content(of: $1)) }
}

/// Drives `count` sequential `respond(to:)` turns on `session`, each with the
/// prompt `"turn <index>"`. This is the warm-up shape every suite that
/// compacts uses. It is in one place so the prompts cannot be different
/// between suites.
///
/// - Parameters:
///   - count: How many turns to drive.
///   - session: The session to drive them on.
/// - Throws: Whatever `respond(to:)` throws.
func driveTurns(_ count: Int, on session: RoutedSession) async throws {
    for index in 0..<count {
        _ = try await session.respond(to: "turn \(index)")
    }
}

/// A budget that makes a compaction of `entries` call its summarizer.
///
/// The limit is the size of `entries`, and the target is the default target
/// of ``TokenBudget``, a part of that limit. Thus the live context is larger
/// than the target, and the compaction makes its one summarizer call. The
/// summary gets the room that the target leaves after the instructions and
/// the protected entries.
///
/// - Parameter entries: The live transcript entries about to be compacted.
/// - Returns: The budget to pass to `compact(budget:)`.
func summarizingCompactionBudget(for entries: [Transcript.Entry]) -> TokenBudget {
    TokenBudget(limit: characterCount(of: entries))
}

extension TokenBudget {
    /// The size the compaction of `entries` allows its summary, in tokens,
    /// when no tool output is protected and no run is pending: this budget's
    /// target less the instructions. ``characterTokenCounter`` measures the
    /// instructions.
    ///
    /// - Parameter entries: The live transcript entries about to be compacted.
    /// - Returns: The allowed summary size, in tokens.
    func allowedSummaryTokens(for entries: [Transcript.Entry]) -> Int {
        let instructions = entries.filter {
            if case .instructions = $0 { return true }
            return false
        }
        return targetTokens - characterCount(of: instructions)
    }
}

/// A summarizer slot of the own-model tier whose window has no bound, so
/// every call fits in it.
///
/// A test that is not about the window gives the compaction this slot.
///
/// - Parameter summarizer: The summarizer the call goes to.
/// - Returns: The slot.
func unboundedOwnModelSlot(_ summarizer: any CompactionSummarizer) -> CompactionSummarizerSlot {
    CompactionSummarizerSlot(tier: .ownModel, summarizer: summarizer, windowTokens: .max, model: nil)
}

/// Compacts `transcript` with the character counter and one own-model slot
/// whose window has no bound.
///
/// - Parameters:
///   - transcript: The live context to compact.
///   - budget: The token budget to compact against.
///   - summarizer: The summarizer the call goes to.
///   - prompt: The compaction prompt. Defaults to ``CompactionPrompt/default``.
///   - pendingRuns: The run-plane summaries of the runs still running.
///     Defaults to none.
///   - protection: The host rule, or `nil` (the default) to protect nothing.
/// - Returns: The new live context and the result.
/// - Throws: What the compaction throws.
func compactWithUnboundedWindow(
    _ transcript: Transcript,
    budget: TokenBudget,
    summarizer: any CompactionSummarizer,
    prompt: CompactionPrompt = .default,
    pendingRuns: [CompactionSegment.PendingRunSummary] = [],
    protection: ToolOutputProtection? = nil
) async throws -> (transcript: Transcript, result: CompactionResult) {
    try await Compactor.compact(
        transcript, prompt: prompt, budget: budget, counter: characterTokenCounter,
        summarizers: [unboundedOwnModelSlot(summarizer)], pendingRuns: pendingRuns, protection: protection)
}

/// A budget whose target is one token under the size of `transcript`, so a
/// compaction runs and the summary gets almost all of the room.
///
/// - Parameter transcript: The live context to compact.
/// - Returns: The budget.
/// - Throws: What ``characterTokenCounter`` throws.
func budgetJustUnder(_ transcript: Transcript) throws -> TokenBudget {
    let before = try characterTokenCounter.count(transcript)
    return TokenBudget(limit: before, target: Double(before - 1) / Double(before))
}

/// Transcript entries of an exact size under ``characterTokenCounter``: an
/// entry of `tokens` tokens holds a text of `tokens` characters.
enum SizedEntries {
    /// A text of `tokens` characters, all equal to `letter`.
    ///
    /// - Parameters:
    ///   - tokens: The size of the text, in tokens.
    ///   - letter: The character the text repeats.
    /// - Returns: The text.
    static func text(tokens: Int, letter: Character) -> String {
        String(repeating: String(letter), count: tokens)
    }

    /// An `.instructions` entry of `tokens` tokens.
    ///
    /// - Parameters:
    ///   - id: The entry id.
    ///   - tokens: The size of the entry, in tokens.
    /// - Returns: The entry.
    static func instructions(id: String, tokens: Int) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: id, segments: [.text(Transcript.TextSegment(content: text(tokens: tokens, letter: "i")))],
                toolDefinitions: []))
    }

    /// A `.prompt` entry of `tokens` tokens.
    ///
    /// - Parameters:
    ///   - id: The entry id.
    ///   - tokens: The size of the entry, in tokens.
    /// - Returns: The entry.
    static func prompt(id: String, tokens: Int) -> Transcript.Entry {
        .prompt(Transcript.Prompt(id: id, segments: [.text(Transcript.TextSegment(content: text(tokens: tokens, letter: "p")))]))
    }

    /// A `.response` entry of `tokens` tokens.
    ///
    /// - Parameters:
    ///   - id: The entry id.
    ///   - tokens: The size of the entry, in tokens.
    /// - Returns: The entry.
    static func response(id: String, tokens: Int) -> Transcript.Entry {
        .response(
            Transcript.Response(id: id, segments: [.text(Transcript.TextSegment(content: text(tokens: tokens, letter: "r")))]))
    }
}

/// The compaction checkpoint a summary entry carries.
///
/// - Parameter entry: The summary entry.
/// - Returns: The checkpoint content, or `nil` when `entry` carries none.
/// - Throws: What `CompactionSegment(structuredSegment:)` throws.
func checkpointContent(of entry: Transcript.Entry) throws -> CompactionSegment.Content? {
    guard case .response(let response) = entry else { return nil }
    for case .structure(let segment) in response.segments {
        if let compaction = try CompactionSegment(structuredSegment: segment) {
            return compaction.content
        }
    }
    return nil
}
