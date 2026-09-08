import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Holds ``StubSessionBackend`` to the one concurrency contract the session
/// needs from a backend: a read of ``StubSessionBackend/transcriptEntries()``
/// is safe beside a stream producer that is still writing, and it sees a turn
/// whole or not at all.
///
/// This is the shape of task ^9smkhk8's trap. A wrapper drives a stub's
/// `streamResponse` from a producer task of its own. A test cancels the turn.
/// The producer keeps going and appends the turn's `.prompt` and `.response`
/// entries, while the cancelled turn's failed-turn recording reads
/// `transcriptEntries()` on the actor. With no lock, the read copied an array
/// buffer the append was freeing, and `recordTranscriptDelta` trapped when it
/// retained the slice.
@Suite("StubSessionBackend beside a stream producer that outlives its turn")
struct StubSessionBackendConcurrencyTests {
    /// How many streaming turns the producer drives while the reader watches.
    /// Each turn appends two entries.
    private static let producedTurns = 2_000

    /// The entries every produced turn appends: one `.prompt`, one `.response`.
    private static let entriesPerTurn = 2

    @Test("transcriptEntries() read beside a live producer sees whole turns only")
    func transcriptReadBesideLiveProducerSeesWholeTurns() async throws {
        let backend = StubSessionBackend()
        let expectedEntryCount = Self.producedTurns * Self.entriesPerTurn

        // The producer: what a stream's own task does after the turn that
        // started it was cut short — it keeps driving the stub.
        let producer = Task.detached {
            for turn in 0..<Self.producedTurns {
                for try await _ in backend.streamResponse(to: "turn \(turn)", maxTokens: nil) {}
            }
        }

        // The reader: what the failed turn's recording does, repeated until the
        // producer is done. A count that is not a multiple of the entries one
        // turn appends is a turn seen half-written.
        var tornReads = 0
        var lastCount = 0
        while lastCount < expectedEntryCount {
            lastCount = backend.transcriptEntries().count
            if lastCount % Self.entriesPerTurn != 0 {
                tornReads += 1
            }
        }
        try await producer.value

        #expect(tornReads == 0)
        #expect(backend.transcriptEntries().count == expectedEntryCount)
        #expect(backend.callCount == Self.producedTurns)
    }
}
