import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

// `ConcurrencyPeakObserver` — the one concurrency counter every suite that
// must measure overlap uses — lives in `FoundationModelsRouterTestSupport`,
// because more than one test target reads it and SwiftPM cannot share source
// between two test targets.

/// A backend that reports each entry into its model call, and each exit from
/// it, to a ``ConcurrencyPeakObserver``, and that stays inside the call until a
/// ``RunLatch`` opens.
///
/// The open call is what makes a generation gate observable: a turn keeps the
/// container's one generation permit for as long as its model call runs, so a
/// second turn either suspends on that permit or shows that it never had to.
///
/// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
/// owning session drives one backend method at a time, and the observer it
/// reports to is an actor.
final class ObservingSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The text an answer opens with, so a test can tell the answer of one turn
    /// from the answer of another.
    static let answerPrefix = "answered: "

    /// The answer this backend gives to a prompt.
    ///
    /// - Parameter prompt: The prompt a turn was given.
    /// - Returns: The expected answer text.
    static func answer(to prompt: String) -> String {
        answerPrefix + prompt
    }

    /// The observer this backend reports its own entry and exit to.
    private let observer: ConcurrencyPeakObserver

    /// The latch a call stays inside the container until a test opens.
    private let latch: RunLatch

    /// Creates a backend over one observer and one latch.
    ///
    /// - Parameters:
    ///   - observer: The observer each entry and each exit is reported to.
    ///   - latch: The latch a call waits on before it answers.
    init(observer: ConcurrencyPeakObserver, latch: RunLatch) {
        self.observer = observer
        self.latch = latch
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        await observer.enter()
        await latch.waitUntilOpen()
        await observer.exit()
        return Self.answer(to: prompt)
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Self.answer(to: prompt))
            continuation.finish()
        }
    }

    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await respond(to: prompt, maxTokens: maxTokens)
    }

    func makeFork() -> any LanguageModelSessionBackend { self }

    func transcriptEntries() -> [Transcript.Entry] { [] }

    func usageTokenCounts() -> (input: Int, output: Int)? { nil }
}

/// A container that gives each session its own ``ObservingSessionBackend``,
/// with every backend reporting to one observer and held by one latch.
///
/// It conforms to ``LoadedLLMContainer`` directly, and not to
/// ``PlainTranscriptStubContainer``, because a session built from a transcript
/// must report to the same observer. A plain stub backend reports to nothing.
struct ObservingLLMContainer: LoadedLLMContainer {
    /// The observer every backend of this container reports to.
    let observer: ConcurrencyPeakObserver

    /// The latch every backend of this container waits on.
    let latch: RunLatch

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        ObservingSessionBackend(observer: observer, latch: latch)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        ObservingSessionBackend(observer: observer, latch: latch)
    }
}
