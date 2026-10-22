import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A ``LoadedLLMContainer`` stub that keeps the last ``StubSessionBackend``
/// it vends, fresh (`makeSession(instructions:)`) and restore-seeded
/// (`makeSession(transcript:)`) alike, so a test can read the live entries a
/// session holds and derive an exact budget that makes a compaction call its
/// summarizer (``summarizingCompactionBudget(for:)``).
///
/// The suites that drive a real compaction of a live session over stubs
/// share this one copy.
final class RetainingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The canned text every backend this container vends responds with.
    let responseText: String

    /// The most recently vended backend, for entry inspection.
    private(set) var lastBackend: StubSessionBackend?

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
        lastBackend = backend
        return backend
    }

    /// Makes a backend seeded with `transcript` and keeps it as
    /// ``lastBackend``.
    ///
    /// - Parameter transcript: The restored transcript.
    /// - Returns: The new backend.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        let backend = StubSessionBackend(responseText: responseText, entries: Array(transcript))
        lastBackend = backend
        return backend
    }
}
