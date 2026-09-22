import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// The `keepRecentTurns` recency window the estimates in this file key on —
/// the same count of newest turns each compaction stage (``ToolOutputElision``,
/// ``TurnTruncation``, ``Summarization``) keeps un-compactable by default, so
/// the fixture floor and the compaction pipeline agree on which turns cannot compact.
let defaultKeepRecentTurns = 4

/// The divisor that puts ``deterministicCompactionBudget(for:protection:)``'s target
/// token count at the midpoint of its two bounds — the floor ``TurnTruncation``
/// leaves and the full pre-compaction estimate — strictly between them.
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

/// The estimated token size of just `entries`' un-compactable recency window
/// (the header plus the newest `defaultKeepRecentTurns` turns) — the floor
/// no deterministic stage can compact below.
///
/// A `TokenBudget` whose target sits strictly between this floor and the
/// full pre-compaction estimate is what forces a *deterministic* compaction: low enough
/// that the pipeline compacts something, high enough that ``TurnTruncation``
/// alone lands under it, so the model-assisted ``Summarization`` stage never
/// runs. A target strictly under this floor forces ``Summarization`` to run
/// instead.
///
/// - Parameter entries: The live transcript entries about to be compacted.
/// - Returns: The recency-window-only token estimate.
func recencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
    let (header, turns) = TranscriptTurns.split(entries)
    let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: defaultKeepRecentTurns)
    return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
}

/// A budget whose target sits strictly between what ``TurnTruncation`` leaves
/// of `entries` and its full estimate — the deterministic-shrink budget:
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
    let preCompactionTokens = Compactor.estimatedTokenCount(of: Transcript(entries: entries))
    let truncation = TurnTruncation(keepRecentTurns: defaultKeepRecentTurns, protection: protection)
    let floorTokens = Compactor.estimatedTokenCount(of: truncation.apply(Transcript(entries: entries)))
    let targetTokens = (floorTokens + preCompactionTokens) / compactionTargetMidpointDivisor
    return TokenBudget(limit: preCompactionTokens, target: Double(targetTokens) / Double(preCompactionTokens))
}
