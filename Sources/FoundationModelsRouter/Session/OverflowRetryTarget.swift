import os

/// The logger for the compaction that follows a context overflow.
private let overflowRetryLogger = makeModuleLogger(category: "OverflowRetry")

/// The compaction target of the one retry that follows a context overflow.
///
/// An overflow means that the transcript, the prompt and the response room do
/// not fit the window together. The prompt and the response room do not change
/// on the retry, so the transcript must shrink to the room that is left:
/// ``contextTokens`` minus ``promptTokens`` minus ``responseTokenCeiling``. The
/// retry compacts to that room, and never to more than the configured target
/// of the budget (``configuredTargetTokens``).
///
/// A ``SessionEvent/compaction(_:)`` event from the retry carries this value in
/// ``CompactionResult/overflowRetryTarget``, so a reader sees what the retry
/// aimed for and why.
public struct OverflowRetryTarget: Sendable, Equatable {
    /// The resolved working context of the session, in tokens.
    public let contextTokens: Int

    /// The size of the retry's prompt, in tokens, as the session's
    /// ``TokenCounter`` counts it.
    public let promptTokens: Int

    /// The token ceiling the turn gave the backend for its response.
    public let responseTokenCeiling: Int

    /// The configured target of the budget, in tokens
    /// (``TokenBudget/targetTokens``).
    public let configuredTargetTokens: Int

    /// Makes the target of the retry.
    ///
    /// - Parameters:
    ///   - contextTokens: The resolved working context of the session, in tokens.
    ///   - promptTokens: The size of the retry's prompt, in tokens.
    ///   - responseTokenCeiling: The token ceiling the turn gave the backend, or
    ///     `nil` when it gave none.
    ///   - configuredTargetTokens: The configured target of the budget, in tokens.
    /// - Returns: `nil` when the turn gave the backend no ceiling. The turn
    ///   gives none only when the window is unknown, and with no window no room
    ///   can be computed.
    init?(contextTokens: Int, promptTokens: Int, responseTokenCeiling: Int?, configuredTargetTokens: Int) {
        guard let responseTokenCeiling else { return nil }
        self.contextTokens = contextTokens
        self.promptTokens = promptTokens
        self.responseTokenCeiling = responseTokenCeiling
        self.configuredTargetTokens = configuredTargetTokens
    }

    /// The room, in tokens, that the window keeps for the transcript after the
    /// prompt and the response room.
    public var roomTokens: Int {
        contextTokens - promptTokens - responseTokenCeiling
    }

    /// The size, in tokens, the retry compacts the transcript to: ``roomTokens``,
    /// capped at ``configuredTargetTokens``.
    public var targetTokens: Int {
        min(roomTokens, configuredTargetTokens)
    }

    /// Whether a compaction can make the turn fit. When ``targetTokens`` is not
    /// positive, the prompt and the response room alone fill the window, and no
    /// compaction helps.
    public var leavesRoom: Bool {
        targetTokens > 0
    }

    /// The budget the retry's compaction runs against: `configured`, with its
    /// target set to ``targetTokens``. The limit and the trigger do not change.
    ///
    /// - Parameter configured: The session's own budget. Its limit is not zero
    ///   when ``leavesRoom`` is true, because ``configuredTargetTokens`` is then
    ///   positive.
    /// - Returns: The budget of the retry's compaction.
    func budget(lowering configured: TokenBudget) -> TokenBudget {
        TokenBudget(
            limit: configured.limit, trigger: configured.trigger,
            target: Double(targetTokens) / Double(configured.limit))
    }

    /// Records in the log what the retry aims for and why, or that no
    /// compaction can make the turn fit.
    ///
    /// - Parameter sessionID: The session whose turn overflowed.
    func log(sessionID: ULID) {
        let outcome =
            leavesRoom
            ? "the retry compacts the transcript to \(targetTokens) tokens"
            : "no compaction makes the turn fit, so the turn does not retry"
        overflowRetryLogger.warning(
            "session \(sessionID.description, privacy: .public): context overflow; window \(contextTokens, privacy: .public) - prompt \(promptTokens, privacy: .public) - response ceiling \(responseTokenCeiling, privacy: .public) leaves \(roomTokens, privacy: .public) tokens; configured target \(configuredTargetTokens, privacy: .public) tokens; \(outcome, privacy: .public)"
        )
    }
}
