import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Holds ``StubSessionBackend`` to the one concurrency contract the session
/// needs from a backend: a read of ``StubSessionBackend/transcriptEntries()``
/// is safe beside a stream producer that is still writing, and it sees a
/// submission whole or not at all.
///
/// This is the shape of task ^9smkhk8's trap. A wrapper drives a stub's
/// `streamResponse` from a producer task of its own. A test cancels the
/// submission. The producer keeps going and appends the `.prompt` and
/// `.response` entries of the submission, while the recording of the cancelled
/// submission reads `transcriptEntries()` on the actor. With no lock, the read
/// copied an array buffer the append was freeing, and `recordTranscriptDelta`
/// trapped when it retained the slice.
@Suite("StubSessionBackend beside a stream producer that outlives its submission")
struct StubSessionBackendConcurrencyTests {
    /// How many streaming submissions the producer drives while the reader
    /// watches. Each submission appends two entries.
    private static let producedSubmissions = 2_000

    /// The entries every produced submission appends: one `.prompt`, one
    /// `.response`.
    private static let entriesPerSubmission = 2

    @Test("transcriptEntries() read beside a live producer sees whole submissions only")
    func transcriptReadBesideLiveProducerSeesWholeSubmissions() async throws {
        let backend = StubSessionBackend()
        let expectedEntryCount = Self.producedSubmissions * Self.entriesPerSubmission

        // The producer: what a stream's own task does after the submission
        // that started it was cut short — it keeps driving the stub.
        let producer = Task.detached {
            for submission in 0..<Self.producedSubmissions {
                for try await _ in backend.streamResponse(to: "submission \(submission)", maxTokens: nil) {}
            }
        }

        // The reader: what the recording of the failed submission does,
        // repeated until the producer is done. A count that is not a multiple
        // of the entries one submission appends is a submission seen
        // half-written.
        var tornReads = 0
        var lastCount = 0
        while lastCount < expectedEntryCount {
            lastCount = backend.transcriptEntries().count
            if lastCount % Self.entriesPerSubmission != 0 {
                tornReads += 1
            }
        }
        try await producer.value

        #expect(tornReads == 0)
        #expect(backend.transcriptEntries().count == expectedEntryCount)
        #expect(backend.callCount == Self.producedSubmissions)
    }
}
