import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// A ``LoadedLLMContainer`` stub that keeps the last ``StubSessionBackend``
/// it vends, fresh (`makeSession(instructions:)`) and restore-seeded
/// (`makeSession(transcript:)`) alike, so a test can read the live entries a
/// session holds and derive an exact budget that makes a compaction call its
/// summarizer (``summarizingCompactionBudget(for:)``).
///
/// The suites that drive a real compaction of a live session over stubs
/// share this one copy. The last vended backend sits behind a `Mutex`, so
/// the container is `Sendable` with no unchecked claim.
final class RetainingLLMContainer: LoadedLLMContainer, Sendable {
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The canned text every backend this container vends responds with.
    let responseText: String

    /// The backend the last vend made, or `nil` before a vend.
    private let vended = Mutex<StubSessionBackend?>(nil)

    /// The most recently vended backend, for entry inspection.
    var lastBackend: StubSessionBackend? { vended.withLock { $0 } }

    /// Creates a container whose backends respond with `responseText`.
    ///
    /// - Parameter responseText: The text of each answer and of each
    ///   summarizer call.
    init(responseText: String) {
        self.responseText = responseText
    }

    /// Makes a fresh backend and keeps it as ``lastBackend``.
    ///
    /// - Parameter instructions: The instructions of the session.
    /// - Returns: The new backend.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        let backend = StubSessionBackend(responseText: responseText, instructions: instructions)
        vended.withLock { $0 = backend }
        return backend
    }

    /// Makes a backend seeded with `transcript` and keeps it as
    /// ``lastBackend``.
    ///
    /// - Parameter transcript: The restored transcript.
    /// - Returns: The new backend.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        let backend = StubSessionBackend(responseText: responseText, entries: Array(transcript))
        vended.withLock { $0 = backend }
        return backend
    }
}
