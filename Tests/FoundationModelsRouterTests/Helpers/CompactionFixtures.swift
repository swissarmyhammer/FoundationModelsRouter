import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// The counter every size in this test target is measured with: one token
/// per `Character`, the rule ``CharacterTokenCounter`` states. A budget a
/// test derives from this counter is in the unit the compaction pipeline
/// measures in, because each test hands the pipeline this same counter.
let characterTokenCounter = CharacterTokenCounter()

/// The size, in characters, of `entries` under ``characterTokenCounter``.
///
/// The count is made entry by entry through
/// ``CharacterTokenCounter/content(of:)``, which does not throw, so the budget
/// helpers below can run inside a stored property's initializer. The result
/// is equal to what the counter's transcript overload counts for a transcript
/// of the same entries.
///
/// - Parameter entries: The transcript entries to count.
/// - Returns: The number of characters the model reads `entries` as.
func characterCount(of entries: [Transcript.Entry]) -> Int {
    entries.reduce(0) { $0 + characterTokenCounter.count(CharacterTokenCounter.content(of: $1)) }
}

/// The `keepRecentTurns` recency window the counts in this file key on —
/// the same count of newest turns each compaction stage (``ToolOutputElision``,
/// ``TurnTruncation``, ``Summarization``) keeps un-compactable by default, so
/// the fixture floor and the compaction pipeline agree on which turns cannot compact.
let defaultKeepRecentTurns = 4

/// The divisor that puts ``deterministicCompactionBudget(for:protection:)``'s target
/// token count at the midpoint of its two bounds — the floor ``TurnTruncation``
/// leaves and the full pre-compaction count — strictly between them.
let compactionTargetMidpointDivisor = 2

/// Drives `count` sequential `respond(to:)` turns on `session`, each with the
/// prompt `"turn <index>"` — the warm-up shape every compaction-exercising suite
/// uses, kept in one place so the prompts (which compaction assertions such as
/// ``renderedLineOfNewestCompactedTurn(turnCount:keepRecentTurns:)`` key on)
/// cannot drift between suites.
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

/// The size, in characters, of just `entries`' un-compactable recency window
/// (the header plus the newest `defaultKeepRecentTurns` turns) — the floor
/// no deterministic stage can compact below.
///
/// A `TokenBudget` whose target sits strictly between this floor and the
/// full pre-compaction count is what forces a *deterministic* compaction: low enough
/// that the pipeline compacts something, high enough that ``TurnTruncation``
/// alone lands under it, so the model-assisted ``Summarization`` stage never
/// runs. A target strictly under this floor forces ``Summarization`` to run
/// instead.
///
/// - Parameter entries: The live transcript entries about to be compacted.
/// - Returns: The recency-window-only character count.
func recencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
    let (header, turns) = TranscriptTurns.split(entries)
    let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: defaultKeepRecentTurns)
    return characterCount(of: header + recent.flatMap(\.entries))
}

/// A budget whose target sits strictly between what ``TurnTruncation`` leaves
/// of `entries` and its full count — the deterministic-shrink budget:
/// guaranteed to compact something, and guaranteed that ``TurnTruncation`` alone
/// lands under target, so no model-assisted ``Summarization`` stage runs and
/// no synthesized summary entry skews what a test measures.
///
/// With no rule, ``TurnTruncation`` leaves the recency window only, so the
/// floor is ``recencyWindowOnlyEstimate(_:)``. With a rule, it also keeps the
/// protected pairs of the old turns, and the floor holds them too.
///
/// - Parameters:
///   - entries: The live transcript entries about to be compacted.
///   - protection: The host rule the session compacts with, or `nil` (the
///     default) for a session with no rule.
/// - Returns: The budget to pass to `compact(budget:)`.
func deterministicCompactionBudget(
    for entries: [Transcript.Entry], protection: ToolOutputProtection? = nil
) -> TokenBudget {
    let preCompactionTokens = characterCount(of: entries)
    let truncation = TurnTruncation(keepRecentTurns: defaultKeepRecentTurns, protection: protection)
    let floorTokens = characterCount(of: Array(truncation.apply(Transcript(entries: entries))))
    let targetTokens = (floorTokens + preCompactionTokens) / compactionTargetMidpointDivisor
    return TokenBudget(limit: preCompactionTokens, target: Double(targetTokens) / Double(preCompactionTokens))
}
