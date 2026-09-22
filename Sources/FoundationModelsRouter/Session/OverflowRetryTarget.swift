import os

/// The logger for the compaction that follows a context overflow.
private let overflowRetryLogger = makeModuleLogger(category: "OverflowRetry")

/// The compaction target of the one retry that follows a context overflow.
///
/// An overflow means that the transcript, the prompt and the response room do
/// not fit the window together. The ``rule`` states which rule
/// chose the target:
///
/// - ``Rule/callerCeiling(_:)``: the caller named a response ceiling. The
///   prompt and the response room do not change on the retry, so the
///   transcript must shrink to the room that is left: ``contextTokens`` minus
///   ``promptTokens`` minus the ceiling. The retry compacts to that room, and
///   never to more than the configured target of the budget
///   (``configuredTargetTokens``).
/// - ``Rule/configuredTarget``: the caller named no ceiling, so the turn gave
///   the backend the whole window. No room can be computed from that ceiling.
///   The retry compacts to the configured target of the budget.
///
/// A ``SessionEvent/compaction(_:)`` event from the retry carries this value in
/// ``CompactionResult/overflowRetryTarget``, so a reader sees what the retry
/// aimed for and why.
public struct OverflowRetryTarget: Sendable, Equatable {
    /// The rule that chose the target of the retry.
    public enum Rule: Sendable, Equatable {
        /// The caller named this response ceiling, in tokens. The target is the
        /// room the window keeps for the transcript after the prompt and this
        /// ceiling, capped at the configured target.
        case callerCeiling(Int)

        /// The caller named no response ceiling. The target is the configured
        /// target of the budget (``TokenBudget/targetTokens``).
        case configuredTarget
    }

    /// The rule that chose the target.
    public let rule: Rule

    /// The resolved working context of the session, in tokens.
    public let contextTokens: Int

    /// The size of the retry's prompt, in tokens, as the session's
    /// ``TokenCounter`` counts it.
    public let promptTokens: Int

    /// The configured target of the budget, in tokens
    /// (``TokenBudget/targetTokens``).
    public let configuredTargetTokens: Int

    /// Makes the target of the retry.
    ///
    /// - Parameters:
    ///   - rule: The rule that chooses the target.
    ///   - contextTokens: The resolved working context of the session, in tokens.
    ///   - promptTokens: The size of the retry's prompt, in tokens.
    ///   - configuredTargetTokens: The configured target of the budget, in tokens.
    init(rule: Rule, contextTokens: Int, promptTokens: Int, configuredTargetTokens: Int) {
        self.rule = rule
        self.contextTokens = contextTokens
        self.promptTokens = promptTokens
        self.configuredTargetTokens = configuredTargetTokens
    }

    /// The response ceiling the caller named, in tokens, or `nil` under
    /// ``Rule/configuredTarget``.
    public var responseTokenCeiling: Int? {
        guard case .callerCeiling(let ceiling) = rule else { return nil }
        return ceiling
    }

    /// The room, in tokens, that the window keeps for the transcript after the
    /// prompt and the caller's response ceiling, or `nil` under
    /// ``Rule/configuredTarget``.
    public var roomTokens: Int? {
        responseTokenCeiling.map(room(after:))
    }

    /// The room, in tokens, that the window keeps for the transcript after the
    /// prompt and `ceiling`.
    ///
    /// - Parameter ceiling: The response ceiling the caller named, in tokens.
    /// - Returns: ``contextTokens`` minus ``promptTokens`` minus `ceiling`.
    private func room(after ceiling: Int) -> Int {
        contextTokens - promptTokens - ceiling
    }

    /// The size, in tokens, the retry compacts the transcript to. Under
    /// ``Rule/callerCeiling(_:)`` it is ``roomTokens``, capped at
    /// ``configuredTargetTokens``. Under ``Rule/configuredTarget`` it is
    /// ``configuredTargetTokens``.
    public var targetTokens: Int {
        guard let roomTokens else { return configuredTargetTokens }
        return min(roomTokens, configuredTargetTokens)
    }

    /// Whether a compaction can make the turn fit. When ``targetTokens`` is not
    /// positive, no compaction helps.
    public var leavesRoom: Bool {
        targetTokens > 0
    }

    /// The budget the retry's compaction runs against. Under
    /// ``Rule/configuredTarget`` it is `configured` unchanged. Under
    /// ``Rule/callerCeiling(_:)`` it is `configured` with its target set to
    /// ``targetTokens``; the limit and the trigger do not change.
    ///
    /// - Parameter configured: The session's own budget. Its limit is not zero
    ///   when ``leavesRoom`` is true, because ``configuredTargetTokens`` is then
    ///   positive.
    /// - Returns: The budget of the retry's compaction.
    func budget(lowering configured: TokenBudget) -> TokenBudget {
        guard case .callerCeiling = rule else { return configured }
        return TokenBudget(
            limit: configured.limit, trigger: configured.trigger,
            target: Double(targetTokens) / Double(configured.limit))
    }

    /// Records in the log which rule chose the target, what the retry aims
    /// for, or that no compaction can make the turn fit.
    ///
    /// - Parameter sessionID: The session whose turn overflowed.
    func log(sessionID: ULID) {
        let outcome =
            leavesRoom
            ? "the retry compacts the transcript to \(targetTokens) tokens"
            : "no compaction makes the turn fit, so the turn does not retry"
        overflowRetryLogger.warning(
            "session \(sessionID.description, privacy: .public): context overflow; window \(contextTokens, privacy: .public), prompt \(promptTokens, privacy: .public), configured target \(configuredTargetTokens, privacy: .public) tokens; \(ruleDescription, privacy: .public); \(outcome, privacy: .public)"
        )
    }

    /// The log text that names the rule that chose the target, with the numbers
    /// that rule used.
    private var ruleDescription: String {
        switch rule {
        case .callerCeiling(let ceiling):
            "rule: the caller's response ceiling \(ceiling) leaves \(room(after: ceiling)) tokens of room"
        case .configuredTarget:
            "rule: the caller named no response ceiling, so the target is the configured target"
        }
    }
}
