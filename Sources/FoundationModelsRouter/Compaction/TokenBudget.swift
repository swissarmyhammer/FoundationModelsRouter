import Foundation

/// The token thresholds that control when and how far a session folds its
/// transcript. Every threshold is a fraction of `limit`, not of the
/// session's window.
public struct TokenBudget: Sendable, Equatable, Codable {
    /// The working context, in tokens, that this budget measures against.
    public var limit: Int

    /// The fraction of ``limit`` at which a session compacts.
    public var trigger: Double

    /// The fraction of ``limit`` a fold compacts down to.
    public var target: Double

    /// The optional hard ceiling, as a fraction of ``limit``. When usage is at
    /// or above it before a generate call, the session throws
    /// ``ContextBudgetError/hardCeilingExceeded(fill:ceiling:)``.
    public var hardCeiling: Double?

    /// The optional cap, in tokens, on one tool result. A larger `String`
    /// result is truncated with a `"… [truncated: N of M tokens]"` marker.
    public var toolOutputLimit: Int?

    /// Creates a token budget. `trigger` defaults to `0.80` and `target` to `0.50`.
    public init(
        limit: Int,
        trigger: Double = 0.80,
        target: Double = 0.50,
        hardCeiling: Double? = nil,
        toolOutputLimit: Int? = nil
    ) {
        self.limit = limit
        self.trigger = trigger
        self.target = target
        self.hardCeiling = hardCeiling
        self.toolOutputLimit = toolOutputLimit
    }

    /// ``trigger`` resolved against ``limit``, in tokens.
    public var triggerTokens: Int {
        tokens(for: trigger)
    }

    /// ``target`` resolved against ``limit``, in tokens.
    public var targetTokens: Int {
        tokens(for: target)
    }

    /// ``hardCeiling`` resolved against ``limit``, in tokens, or `nil`.
    public var ceilingTokens: Int? {
        hardCeiling.map(tokens(for:))
    }

    /// Returns `measuredTokens` as a fraction of ``limit``, or `0` when
    /// ``limit`` is not positive.
    public func fill(measuredTokens: Int) -> Double {
        guard limit > 0 else { return 0 }
        return Double(measuredTokens) / Double(limit)
    }

    /// Resolves `fraction` of ``limit`` to a rounded token count.
    private func tokens(for fraction: Double) -> Int {
        Int((Double(limit) * fraction).rounded())
    }
}

/// A budget failure a session throws before a generate call when measured
/// usage is at or above ``TokenBudget/ceilingTokens``. Auto-compaction
/// treats it like `LanguageModelError.contextSizeExceeded`: it folds and
/// retries once.
public enum ContextBudgetError: Error, Equatable, LocalizedError {
    /// Measured usage (`fill`, as a fraction of ``TokenBudget/limit``) was at
    /// or above ``TokenBudget/hardCeiling`` (`ceiling`).
    case hardCeilingExceeded(fill: Double, ceiling: Double)

    /// A description that names the measured fill and the ceiling.
    public var errorDescription: String? {
        switch self {
        case .hardCeilingExceeded(let fill, let ceiling):
            return """
                Context fill \(fill) is at or above the configured hard ceiling \(ceiling); \
                refusing to submit a doomed generate call.
                """
        }
    }
}

/// The value ``RoutedSession/contextFill`` reports when fill cannot be
/// measured. It is `Double.nan`; test with `.isNaN`.
public let unknownContextFill = Double.nan

/// The measured usage state that ``RoutedSessionActor/contextFill`` reads.
enum ContextUsageState: Sendable, Equatable {
    /// No turn has completed and no persisted stamp was found.
    case none

    /// The most recently measured usage.
    case measured(input: Int, output: Int)

    /// Restored with no stamped `.response` event. Reports ``unknownContextFill``.
    case unknown
}

extension ContextUsageState {
    /// Returns the fill fraction against `contextTokens`, or ``unknownContextFill``.
    func fill(contextTokens: Int) -> Double {
        switch self {
        case .none:
            return 0
        case .unknown:
            return unknownContextFill
        case .measured(let input, let output):
            guard contextTokens > 0 else { return 0 }
            return Double(input + output) / Double(contextTokens)
        }
    }

    /// The measured usage, in tokens, or `nil` when it is ``unknown``.
    var measuredTokens: Int? {
        switch self {
        case .none:
            return 0
        case .unknown:
            return nil
        case .measured(let input, let output):
            return input + output
        }
    }
}

/// Returns the newest stamped `.response` event's `(tokensIn, tokensOut)`
/// in `events`, or `nil` when none carries a stamp. Skips a bodyless close
/// (`entry == nil`): its stamp is not a real measurement.
func newestStampedUsage(in events: [TranscriptEvent]) -> (input: Int, output: Int)? {
    guard
        let stamped = events.last(where: {
            $0.kind == .response && $0.entry != nil && $0.tokensIn != nil && $0.tokensOut != nil
        })
    else {
        return nil
    }
    return (stamped.tokensIn!, stamped.tokensOut!)
}
