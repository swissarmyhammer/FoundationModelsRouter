import Foundation

@testable import FoundationModelsRouter

/// The line ``Summarization`` renders for the newest turn a compaction condenses,
/// for a suite whose warm-up turns are driven with the prompt `"turn <index>"`.
///
/// The stage compacts everything but the header and the newest `keepRecentTurns`
/// turns, so with `turnCount` turns driven the newest compacted turn is
/// `turnCount - keepRecentTurns - 1`, and the stage's renderer writes that
/// turn's prompt as `"User: turn <index>"`. Looking the line up in the prompts
/// a compaction actually handed its summarizer is what says which recency window the
/// compaction ran with — the one the session carries, or the stage's own default.
///
/// - Parameters:
///   - turnCount: How many turns were driven before the compaction.
///   - keepRecentTurns: The recency window to compute the compacted span for.
/// - Returns: The rendered prompt line of the newest turn that window compacts.
func renderedLineOfNewestCompactedTurn(turnCount: Int, keepRecentTurns: Int) -> String {
    "User: turn \(turnCount - keepRecentTurns - 1)"
}
