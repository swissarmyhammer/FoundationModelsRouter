import Foundation

/// The token-accounting knobs governing when and how far a session's
/// transcript gets folded (compaction_plan.md §1.4).
///
/// `limit` has no universal default — it is always the profile's resolved
/// working context (``SlotResolution/contextTokens``), which varies by
/// profile and machine; callers construct a ``TokenBudget`` with that figure
/// in hand (a future compaction task defaults a `nil` budget to it
/// automatically — see compaction_plan.md §1.4's `compact(prompt:budget:)`).
/// `trigger`/`target` are stable defaults, research-backed against Claude
/// Code's and the Claude platform's own compaction guidance
/// (compaction_plan.md §2): fold once a session crosses 80% of its context,
/// back down to 50%.
public struct TokenBudget: Sendable, Equatable {
    /// The working context, in tokens, this budget is measured against —
    /// normally a profile's resolved ``SlotResolution/contextTokens``.
    public var limit: Int

    /// Compact once measured ``RoutedSession/contextFill`` reaches this
    /// fraction of ``limit``.
    public var trigger: Double

    /// Compact down to at most this fraction of ``limit``.
    public var target: Double

    /// Creates a token budget.
    ///
    /// - Parameters:
    ///   - limit: The working context, in tokens, to measure fill against —
    ///     normally a profile's resolved ``SlotResolution/contextTokens``.
    ///   - trigger: Compact once fill reaches this fraction of `limit`.
    ///     Defaults to `0.80`.
    ///   - target: Compact down to at most this fraction of `limit`.
    ///     Defaults to `0.50`.
    public init(limit: Int, trigger: Double = 0.80, target: Double = 0.50) {
        self.limit = limit
        self.trigger = trigger
        self.target = target
    }
}

/// The sentinel ``RoutedSession/contextFill`` reports when fill cannot be
/// measured — never a guessed fraction (compaction_plan.md §1.5).
///
/// Only reachable immediately after
/// ``RoutedModel/restoreSessionTree(root:registry:)`` restores a session
/// whose recorded transcript carries no stamped `tokensIn`/`tokensOut` on any
/// `.response`-kind event (a recording made before per-turn metering
/// existed, or one with metadata stripped) — the very next live turn
/// re-measures exactly and replaces it. `Double.nan` so naive arithmetic on
/// an unchecked read propagates NaN rather than silently producing a wrong
/// number; test with `.isNaN`.
public let unknownContextFill = Double.nan

/// The state ``RoutedSessionActor/contextFill`` derives its numerator
/// from — always a measured per-turn delta, never the backend's raw
/// cumulative running total (compaction_plan.md §1.5).
enum ContextUsageState: Sendable, Equatable {
    /// No turn has completed on this actor, and (for a restored session) no
    /// persisted stamp was found either. A brand-new session's fill is `0` —
    /// nothing has been sent yet.
    case none

    /// The most recently measured usage: a just-completed live turn's
    /// delta, a restored stamped `.response` event, or (for a fork) the
    /// parent's own state as of fork time.
    case measured(input: Int, output: Int)

    /// Restored with no stamped `.response` event to derive a number from,
    /// and no live turn has re-measured yet. Reports ``unknownContextFill``.
    case unknown
}

extension ContextUsageState {
    /// This state's contribution to ``RoutedSession/contextFill`` against
    /// `contextTokens`.
    ///
    /// - Parameter contextTokens: The resolved working context to divide by.
    /// - Returns: The fill fraction, or ``unknownContextFill``.
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
}

/// The newest stamped `.response`-kind event's `(tokensIn, tokensOut)` among
/// `events`, or `nil` when none carries a stamp — a recording made before
/// per-turn metering existed, or one whose metadata was stripped
/// (compaction_plan.md §1.5).
///
/// Skips the router-only synthetic bodyless close a failed turn can leave
/// (`entry == nil` — see `RoutedSessionActor.runTurn`'s catch branch and
/// `TranscriptTree.isFailedTurnBodylessClose`): its `tokensIn`/`tokensOut`
/// are stamped from a usage delta taken around a turn that may never have
/// actually reached the backend (e.g. a guided turn whose grammar
/// validation throws pre-flight), so — unlike a genuine `.response` diffed
/// from the SDK's own transcript, which always carries a non-nil `entry` —
/// this event's stamp is not a real measurement of transcript size and
/// would otherwise silently corrupt restored fill with a bogus (often
/// zero) delta.
///
/// - Parameter events: A session's effective recorded events, in order.
/// - Returns: The newest stamped usage, or `nil`.
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
