import Foundation

/// The short report of one stop of the repetition watch: a repetition stop
/// (``RepetitionStop``) or a reasoning stop (``ReasoningStop``), with the
/// numbers that a host logs (task ^0dcsd3t).
///
/// The run journal records one for each stop
/// (``TranscriptEvent/Kind/watchStop``), and ``SessionAnswer/stop`` gives
/// the one that found no recovery left. A host can then log, for example,
/// `reasoning.limit=8192 reasoning.tokens=8070 recoveries=2/2`
/// (``description``).
public struct WatchStop: Sendable, Equatable, Codable, CustomStringConvertible {
    /// Which stop of the watch this is.
    public enum Kind: String, Sendable, Equatable, Codable {
        /// The call no longer wrote new lines (``RepetitionStop``).
        case repetition

        /// The pass reasoned and did not act (``ReasoningStop``).
        case reasoning
    }

    /// Which stop of the watch this is.
    public let kind: Kind

    /// The tokens that reached ``limit``: for a repetition stop, the tokens
    /// of the repeated lines since the last new line
    /// (``RepetitionStop/tokensWithoutNewLine``); for a reasoning stop, the
    /// reasoning tokens of the pass (``ReasoningStop/reasoningTokens``).
    public let tokens: Int

    /// The limit that the tokens reached: for a repetition stop, the window
    /// (``RepetitionDetection/windowTokens``); for a reasoning stop, the
    /// limit of the pass (``ReasoningStop/limit``), or `nil` when the pass
    /// ended inside its reasoning before a limit.
    public let limit: Int?

    /// Why the stopped pass ended.
    public let passFinishReason: FinishReason

    /// The number of the recovery that follows the stop, from 1, or `nil`
    /// when the answer has no recovery left.
    public let recovery: Int?

    /// How many recoveries one answer runs at most
    /// (``RepetitionDetection/recoveriesPerAnswer``).
    public let recoveriesAllowed: Int

    /// Creates a report.
    ///
    /// - Parameters:
    ///   - kind: Which stop of the watch this is.
    ///   - tokens: The tokens that reached `limit`.
    ///   - limit: The limit that the tokens reached, or `nil`.
    ///   - passFinishReason: Why the stopped pass ended.
    ///   - recovery: The number of the recovery that follows, or `nil`.
    ///   - recoveriesAllowed: How many recoveries one answer runs at most.
    public init(
        kind: Kind, tokens: Int, limit: Int?, passFinishReason: FinishReason, recovery: Int?,
        recoveriesAllowed: Int
    ) {
        self.kind = kind
        self.tokens = tokens
        self.limit = limit
        self.passFinishReason = passFinishReason
        self.recovery = recovery
        self.recoveriesAllowed = recoveriesAllowed
    }

    /// The short report of a repetition stop.
    ///
    /// - Parameter stop: The repetition stop.
    public init(_ stop: RepetitionStop) {
        self.init(
            kind: .repetition, tokens: stop.tokensWithoutNewLine, limit: stop.detection.windowTokens,
            passFinishReason: .repeatedLines, recovery: stop.recovery,
            recoveriesAllowed: stop.detection.recoveriesPerAnswer)
    }

    /// The short report of a reasoning stop.
    ///
    /// - Parameter stop: The reasoning stop.
    public init(_ stop: ReasoningStop) {
        self.init(
            kind: .reasoning, tokens: stop.reasoningTokens, limit: stop.limit,
            passFinishReason: stop.passFinishReason, recovery: stop.recovery,
            recoveriesAllowed: stop.detection.recoveriesPerAnswer)
    }

    /// How many recoveries the answer used before this stop: one less than
    /// ``recovery``, or all of ``recoveriesAllowed`` when no recovery is left.
    public var recoveriesUsed: Int {
        recovery.map { $0 - 1 } ?? recoveriesAllowed
    }

    /// The word for a missing value in ``description``.
    private static let noValue = "none"

    /// One line of `key=value` pairs, for example
    /// `reasoning.limit=8192 reasoning.tokens=8070 recovery=none recoveries=2/2 finish=reasoningTokenLimit`.
    public var description: String {
        let limitText = limit.map(String.init) ?? Self.noValue
        let recoveryText = recovery.map(String.init) ?? Self.noValue
        return """
            \(kind.rawValue).limit=\(limitText) \(kind.rawValue).tokens=\(tokens) recovery=\(recoveryText) \
            recoveries=\(recoveriesUsed)/\(recoveriesAllowed) finish=\(passFinishReason)
            """
    }

    /// The reply of an answer that this stop ended with no text from the
    /// model: it states the stop, so the reply is never empty.
    public var stoppedAnswerText: String {
        "The session stopped the answer before the model gave a final answer (\(description))."
    }
}
