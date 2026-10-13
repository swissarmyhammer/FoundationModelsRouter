import FoundationModelsRouter

/// A compaction that ended with ``SessionEvent/compactionFailed(_:)``, as an
/// error, so a test that waits for a compaction can throw it.
struct CompactionDidNotComplete: Error {
    /// The failure that ended the compaction.
    let failure: CompactionFailure
}

/// An end of a compaction signal that is not a compaction event, for example
/// ``SessionEvent/signalDone(_:)`` of a different kind of signal.
struct UnexpectedCompactionTerminal: Error {
    /// The terminal event that came.
    let event: SessionEvent
}

extension RoutedSession {
    /// Sends the signal ``RoutedSession/compact(prompt:budget:)`` and waits for
    /// its terminal event with ``RoutedSession/awaitTerminal(of:)-(SignalID)``.
    /// This is the form that a caller of the library uses.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt.
    ///   - budget: The token budget, or `nil` for the resolved working context
    ///     of the session.
    /// - Returns: The result of the ``SessionEvent/compaction(_:)`` that ended
    ///   the signal.
    /// - Throws: ``CompactionDidNotComplete`` for a
    ///   ``SessionEvent/compactionFailed(_:)``,
    ///   ``UnexpectedCompactionTerminal`` for a different terminal event, or
    ///   what the wait throws.
    @discardableResult
    func compactAndAwait(prompt: CompactionPrompt = .default, budget: TokenBudget?) async throws -> CompactionResult {
        let id = compact(prompt: prompt, budget: budget)
        let terminal = try await awaitTerminal(of: id)
        switch terminal {
        case .compaction(let result):
            return result
        case .compactionFailed(let failure):
            throw CompactionDidNotComplete(failure: failure)
        default:
            throw UnexpectedCompactionTerminal(event: terminal)
        }
    }
}
