import Foundation

/// Why a compaction ran. Only the reason tells a requested compaction from
/// an automatic one: both run the same handler and send the same events
/// (`mailbox.md`, section 3, "Decision: one compaction, two triggers").
public enum CompactionReason: String, Sendable, Equatable {
    /// A caller asked for the compaction with
    /// ``RoutedSession/compact(prompt:budget:)``, for example the `/compact`
    /// command of a host, a library caller, or a tool. The compaction runs
    /// in the order of the signals of the session, and it is the only
    /// reason that no budget trigger of an answer gives.
    case requested

    /// The measured context reached ``TokenBudget/triggerTokens`` before the
    /// answer started its first submission.
    case triggerReached

    /// A submission failed with a recoverable context overflow. The answer
    /// compacts to its ``OverflowRetryTarget`` and retries one time.
    case contextOverflow

    /// A tool result moved the measured context to the trigger, and the
    /// model call stopped at the tool result so the answer can compact.
    case toolResultYield

    /// A submission stopped at its output token ceiling with the context at
    /// or over the trigger.
    case outputCeilingStop
}

/// The start of a compaction, carried by
/// ``SessionEvent/compactionStarted(_:)``.
public struct CompactionStart: Sendable, Equatable {
    /// The identity of the compaction: the string form of the ``SignalID``
    /// of its compaction signal. The ``CompactionResult/id`` of the
    /// ``SessionEvent/compaction(_:)`` that completes it, or the
    /// ``CompactionFailure/id`` of the ``SessionEvent/compactionFailed(_:)``
    /// that ends it, holds the same value.
    public let id: String

    /// Why the compaction runs.
    public let reason: CompactionReason

    /// Creates a compaction start.
    ///
    /// - Parameters:
    ///   - id: The identity of the compaction.
    ///   - reason: Why the compaction runs.
    public init(id: String, reason: CompactionReason) {
        self.id = id
        self.reason = reason
    }
}

/// A compaction that did not complete, carried by
/// ``SessionEvent/compactionFailed(_:)``. A compaction that fails leaves the
/// live context of the session as it was.
public struct CompactionFailure: Sendable, Equatable {
    /// How the compaction ended.
    public enum Outcome: Sendable, Equatable {
        /// A cancel stopped the compaction: ``RoutedSession/close()``
        /// cancelled its summarizer call. No other signal stops a running
        /// compaction.
        case cancelled

        /// The compaction failed with an error. The text is the description
        /// of the error.
        case failed(String)
    }

    /// The identity of the compaction, the same value as the
    /// ``CompactionStart/id`` of its ``SessionEvent/compactionStarted(_:)``:
    /// the string form of the ``SignalID`` of its compaction signal.
    public let id: String

    /// Why the compaction ran.
    public let reason: CompactionReason

    /// How the compaction ended.
    public let outcome: Outcome

    /// Creates a compaction failure.
    ///
    /// - Parameters:
    ///   - id: The identity of the compaction.
    ///   - reason: Why the compaction ran.
    ///   - outcome: How the compaction ended.
    public init(id: String, reason: CompactionReason, outcome: Outcome) {
        self.id = id
        self.reason = reason
        self.outcome = outcome
    }
}
