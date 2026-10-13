@testable import FoundationModelsRouter

/// A compaction that ended with ``SessionEvent/compactionFailed(_:)``, as an
/// error, so a test that waits for a compaction can throw it.
struct CompactionDidNotComplete: Error, Equatable {
    /// The failure that ended the compaction.
    let failure: CompactionFailure
}

/// An end of a compaction signal that is no compaction event, for example
/// ``SessionEvent/signalDone(_:)`` of a different kind of signal.
struct UnexpectedCompactionTerminal: Error {
    /// The terminal event that came.
    let event: SessionEvent
}

extension RoutedSession {
    /// Sends the signal ``RoutedSession/compact(prompt:budget:)`` and waits for
    /// its terminal event with ``RoutedSession/awaitTerminal(of:)-(SignalID)``:
    /// the form that a caller of the library uses.
    ///
    /// - Parameters:
    ///   - prompt: The compaction prompt.
    ///   - budget: The token budget, or `nil` for the resolved working context
    ///     of the session.
    /// - Returns: The result of the ``SessionEvent/compaction(_:)`` that ended
    ///   the signal.
    /// - Throws: ``CompactionDidNotComplete`` for a
    ///   ``SessionEvent/compactionFailed(_:)``, or what the wait throws.
    @discardableResult
    func compactAndAwait(prompt: CompactionPrompt = .default, budget: TokenBudget?) async throws -> CompactionResult {
        let id = compact(prompt: prompt, budget: budget)
        return try compactionResult(of: try await awaitTerminal(of: id))
    }

    /// See ``compactAndAwait(prompt:budget:)``, with both parameters at their
    /// defaults.
    ///
    /// - Returns: The result of the compaction.
    /// - Throws: ``CompactionDidNotComplete``, or what the wait throws.
    @discardableResult
    func compactAndAwait() async throws -> CompactionResult {
        try await compactAndAwait(prompt: .default, budget: nil)
    }
}

/// The result of the terminal event of a compaction signal.
///
/// - Parameter terminal: The terminal event of the signal.
/// - Returns: The result of a ``SessionEvent/compaction(_:)``.
/// - Throws: ``CompactionDidNotComplete`` for a
///   ``SessionEvent/compactionFailed(_:)``, else
///   ``UnexpectedCompactionTerminal``.
func compactionResult(of terminal: SessionEvent) throws -> CompactionResult {
    switch terminal {
    case .compaction(let result):
        return result
    case .compactionFailed(let failure):
        throw CompactionDidNotComplete(failure: failure)
    default:
        throw UnexpectedCompactionTerminal(event: terminal)
    }
}
