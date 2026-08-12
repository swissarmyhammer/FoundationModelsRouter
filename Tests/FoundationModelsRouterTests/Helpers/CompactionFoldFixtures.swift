import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// The `keepRecentTurns` recency window the estimates in this file key on —
/// the same count of newest turns each fold stage (``ToolOutputElision``,
/// ``TurnTruncation``, ``Summarization``) keeps un-foldable by default, so
/// the fixture floor and the fold pipeline agree on which turns cannot fold.
let defaultKeepRecentTurns = 4

/// The divisor that puts ``deterministicFoldBudget(for:)``'s target token
/// count at the midpoint of its two bounds — the recency-window-only floor
/// and the full pre-fold estimate — strictly between them.
let foldTargetMidpointDivisor = 2

/// Drives `count` sequential `respond(to:)` turns on `session`, each with the
/// prompt `"turn <index>"` — the warm-up shape every fold-exercising suite
/// uses, kept in one place so the prompts (which fold assertions such as
/// ``renderedLineOfNewestFoldedTurn(turnCount:keepRecentTurns:)`` key on)
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

/// The estimated token size of just `entries`' un-foldable recency window
/// (the header plus the newest `defaultKeepRecentTurns` turns) — the floor
/// no deterministic stage can fold below.
///
/// A `TokenBudget` whose target sits strictly between this floor and the
/// full pre-fold estimate is what forces a *deterministic* fold: low enough
/// that the pipeline folds something, high enough that ``TurnTruncation``
/// alone lands under it, so the model-assisted ``Summarization`` stage never
/// runs. A target strictly under this floor forces ``Summarization`` to run
/// instead.
///
/// - Parameter entries: The live transcript entries about to be folded.
/// - Returns: The recency-window-only token estimate.
func recencyWindowOnlyEstimate(_ entries: [Transcript.Entry]) -> Int {
    let (header, turns) = TranscriptTurns.split(entries)
    let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: defaultKeepRecentTurns)
    return Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
}

/// A budget whose target sits strictly between `entries`' recency-window-only
/// floor and its full estimate — the deterministic-shrink budget: guaranteed
/// to fold something, and guaranteed that ``TurnTruncation`` alone lands
/// under target, so no model-assisted ``Summarization`` stage runs and no
/// synthesized summary entry skews what a test measures.
///
/// - Parameter entries: The live transcript entries about to be folded.
/// - Returns: The budget to pass to `compact(budget:)`.
func deterministicFoldBudget(for entries: [Transcript.Entry]) -> TokenBudget {
    let preFoldTokens = Compactor.estimatedTokenCount(of: Transcript(entries: entries))
    let targetTokens = (recencyWindowOnlyEstimate(entries) + preFoldTokens) / foldTargetMidpointDivisor
    return TokenBudget(limit: preFoldTokens, target: Double(targetTokens) / Double(preFoldTokens))
}
