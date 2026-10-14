import Foundation

@testable import FoundationModelsRouter

/// A recorder that keeps each event in an ``InMemoryRecorder`` and signals
/// ``changes`` after each append. A test waits for a journal entry with
/// `changes.wait(until:)`, and with no poll.
actor SignallingTranscriptRecorder: TranscriptRecorder {
    /// The recorder that keeps the events.
    private let inner = InMemoryRecorder()

    /// Signals after each append.
    nonisolated let changes = ChangeSignal()

    /// The stamped events, in append order.
    var events: [TranscriptEvent] {
        get async { await inner.events }
    }

    /// Keeps the event in the inner recorder, then signals ``changes``.
    ///
    /// - Parameters:
    ///   - partial: The event to stamp and keep.
    ///   - directory: The session directory. The inner recorder ignores it.
    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        await inner.append(partial, to: directory)
        changes.signal()
    }
}
