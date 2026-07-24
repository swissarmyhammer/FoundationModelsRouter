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

    /// The optional hard ceiling on measured ``RoutedSession/contextFill``, as
    /// a fraction of ``limit`` — `nil` (the default) opts out entirely
    /// (harness plan §5.1's mid-turn strategy, task g2hcm36).
    ///
    /// Unlike ``trigger`` (compact proactively, ahead of time, so a turn never
    /// dies) this is a deterministic last resort: when set on a session's
    /// auto-compaction budget, ``RoutedSessionActor`` checks fill against it
    /// immediately before submitting a turn's own generate call — after any
    /// proactive fold ``trigger`` already triggered, so this only ever fires
    /// when fill is *still* at or above it (an oversized-tail transcript no
    /// fold could bring down far enough). Fails fast with
    /// ``ContextBudgetError/hardCeilingExceeded(fill:ceiling:)`` instead of
    /// submitting a call doomed to overflow the backend's own context window,
    /// and — because that error is treated exactly like
    /// `LanguageModelError.contextSizeExceeded` — is still recovered by
    /// auto-compaction's own reactive fold-harder-and-retry-once path, only
    /// surfacing to the caller if the retry hits it again.
    public var hardCeiling: Double?

    /// The optional cap, in tokens, on any single tool call's own result —
    /// `nil` (the default) opts out entirely (harness plan §5.1 seam 2, task
    /// 1334fk3).
    ///
    /// Unlike ``limit``/``trigger``/``target`` (measured against the whole
    /// transcript, after the fact) this bounds one tool invocation's output
    /// *before* it ever reaches the model or gets recorded: tool outputs, not
    /// prompts, are what blow a turn's context window mid-turn, and this is
    /// the one seam Router's own tool-instancing pipeline
    /// (``RoutedModel/makeSession(instructions:workingDirectory:tools:budget:compactionPrompt:)``/
    /// ``RoutedSessionActor/fork(workingDirectory:)``) can intercept every
    /// result at. When set, a tool whose own output is `String` and whose
    /// estimated size exceeds this limit is truncated to it, with an
    /// explicit `"… [truncated: N of M tokens]"` marker appended — never
    /// silently dropped — so both the model and a driver watching
    /// ``SessionEvent/toolStatus(id:status:summary:)`` see that a result was
    /// capped. Replaces the harness's own external `ObservedTool` capping
    /// job.
    public var toolOutputLimit: Int?

    /// Creates a token budget.
    ///
    /// - Parameters:
    ///   - limit: The working context, in tokens, to measure fill against —
    ///     normally a profile's resolved ``SlotResolution/contextTokens``.
    ///   - trigger: Compact once fill reaches this fraction of `limit`.
    ///     Defaults to `0.80`.
    ///   - target: Compact down to at most this fraction of `limit`.
    ///     Defaults to `0.50`.
    ///   - hardCeiling: The optional hard ceiling on fill, as a fraction of
    ///     `limit` — see ``hardCeiling``. Defaults to `nil` (opted out).
    ///   - toolOutputLimit: The optional cap, in tokens, on any single tool
    ///     call's own result — see ``toolOutputLimit``. Defaults to `nil`
    ///     (opted out).
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
}

/// A typed, deterministic budget failure raised at the generate boundary
/// itself (harness plan §5.1, task g2hcm36) — the alternative to letting a
/// doomed submission run all the way to the backend and rely on it
/// eventually throwing `LanguageModelError.contextSizeExceeded`.
///
/// Only ever thrown by ``RoutedSessionActor`` when a session's
/// auto-compaction budget sets ``TokenBudget/hardCeiling``: immediately
/// before submitting a turn's own generate call, measured
/// ``RoutedSession/contextFill`` is checked against it, and this is thrown
/// instead of running the call when fill is already at or over the ceiling.
/// Treated exactly like `LanguageModelError.contextSizeExceeded` by
/// auto-compaction's own reactive retry-once recovery: the session folds
/// harder and retries once; a second hit (the fold could not bring fill
/// under the ceiling — an unfoldable oversized transcript) surfaces this to
/// the caller instead of looping.
public enum ContextBudgetError: Error, Equatable, LocalizedError {
    /// Measured ``RoutedSession/contextFill`` (`fill`) was at or above the
    /// configured ``TokenBudget/hardCeiling`` (`ceiling`) immediately before
    /// this turn's generate call would have been submitted.
    case hardCeilingExceeded(fill: Double, ceiling: Double)

    /// A human-readable description naming the measured fill and the
    /// configured ceiling it was checked against.
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
