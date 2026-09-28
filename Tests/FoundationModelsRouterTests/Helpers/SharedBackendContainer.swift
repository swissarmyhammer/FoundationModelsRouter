import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A container that vends one caller-supplied backend for every session it
/// makes, so a test can set the backend up before the session exists and
/// can drive or read the backend after the session exists.
///
/// It conforms to ``LoadedLLMContainer`` directly, and not to
/// ``PlainTranscriptStubContainer``, because that protocol's
/// `makeSession(transcript:)` builds a fresh backend, which would leave the
/// test holding a backend the session no longer runs on.
struct SharedBackendContainer: LoadedLLMContainer {
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The backend every session this container vends runs on.
    let backend: any LanguageModelSessionBackend

    /// Vends ``backend``.
    ///
    /// - Parameter instructions: The session's system instructions, unread:
    ///   the shared backend was built before this call.
    /// - Returns: ``backend``.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        backend
    }

    /// Vends ``backend``.
    ///
    /// - Parameter transcript: The transcript to seed from, unread: the
    ///   shared backend carries its own history.
    /// - Returns: ``backend``.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        backend
    }
}
