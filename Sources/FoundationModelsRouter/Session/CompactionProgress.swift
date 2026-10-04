import Foundation

/// Why an automatic compaction ran inside an answer.
public enum CompactionReason: String, Sendable, Equatable {
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

/// The start of an automatic compaction, carried by
/// ``SessionEvent/compactionStarted(_:)``.
public struct CompactionStart: Sendable, Equatable {
    /// The identity of the compaction. The ``CompactionResult/id`` of the
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

/// An automatic compaction that did not complete, carried by
/// ``SessionEvent/compactionFailed(_:)``. A compaction that fails leaves the
/// live context of the session as it was.
public struct CompactionFailure: Sendable, Equatable {
    /// How the compaction ended.
    public enum Outcome: Sendable, Equatable {
        /// A cancel stopped the compaction: ``RoutedSession/cancel()``,
        /// ``RoutedSession/cancel(message:)``, or the cancel of a caller that
        /// waited for the answer.
        case cancelled

        /// The compaction failed with an error. The text is the description
        /// of the error.
        case failed(String)
    }

    /// The identity of the compaction, the same value as the
    /// ``CompactionStart/id`` of its ``SessionEvent/compactionStarted(_:)``.
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
