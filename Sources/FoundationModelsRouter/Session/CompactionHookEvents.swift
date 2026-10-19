import FoundationModelsHooks

// The compaction hooks of a session: one `CompactionStarted` and one
// `CompactionEnded` for each compaction that starts. The one compaction
// handler (``RoutedSessionActor/performCompaction(_:_:)``) sends each one
// next to its session event: `CompactionStarted` next to
// ``SessionEvent/compactionStarted(_:)``, and `CompactionEnded` next to
// ``SessionEvent/compaction(_:)`` or ``SessionEvent/compactionFailed(_:)``.
// Both events are post events: a compaction has no pre event, because an
// automatic compaction starts when the context is almost full, and a block
// would make the next pass overflow.

extension CompactionStarted {
    /// The `CompactionStarted` of a compaction.
    ///
    /// - Parameter start: The ``SessionEvent/compactionStarted(_:)`` value
    ///   of the compaction. Its id is the id of the hook event.
    init(_ start: CompactionStart) {
        self.init(compactionID: start.id, reason: start.reason.rawValue)
    }
}

extension CompactionEnded {
    /// The `CompactionEnded` of a compaction that completed.
    ///
    /// - Parameter result: What the compaction did.
    init(_ result: CompactionResult) {
        self.init(
            compactionID: result.id,
            outcome: .completed(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter))
    }

    /// The `CompactionEnded` of a compaction that failed or that a cancel
    /// stopped.
    ///
    /// - Parameter failure: How the compaction ended.
    init(_ failure: CompactionFailure) {
        self.init(compactionID: failure.id, outcome: CompactionOutcome(failure.outcome))
    }
}

extension CompactionOutcome {
    /// The hook outcome of a compaction that did not complete.
    ///
    /// - Parameter outcome: How the compaction ended, as the session event
    ///   tells it.
    init(_ outcome: CompactionFailure.Outcome) {
        switch outcome {
        case .cancelled:
            self = .cancelled
        case .failed(let message):
            self = .failed(message: message)
        }
    }
}
