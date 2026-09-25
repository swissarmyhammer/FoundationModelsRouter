import FoundationModels
import FoundationModelsRouterTestSupport
@testable import FoundationModelsRouter

/// A ``LoadedLLMContainer`` that vends the production
/// ``MLXFoundationModelsSessionBackend`` over any scripted `LanguageModel`, so
/// a routed session drives the real backend and a real `LanguageModelSession`
/// with no GPU.
///
/// It is generic over the model, so a suite that brings a new scripted model
/// does not write one more copy of the four factory methods.
///
/// Like the live container, it owns one ``GenerationQueue``, and each backend
/// it vends runs over its own ``SessionLanguageModel`` and declares that
/// queue. A routed session thus submits each whole scripted SDK call, tool
/// loop included, as one item of the queue, with no MLX.
struct LiveBackendContainer<Model: FoundationModels.LanguageModel>: LoadedLLMContainer {
    /// The scripted model every backend of this container runs over.
    let model: Model

    /// The queue every backend of this container shares.
    let generationQueue = GenerationQueue()

    /// The window of ``model``, in tokens. Each backend sends it as the
    /// ceiling of a call that names none. The fixture window by default.
    var contextWindow: Int = ScriptedSessionContext.tokens

    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// Vends a backend over a fresh session carrying `instructions`, with no
    /// tools mounted.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A live backend over ``model``.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    /// Vends a backend over a fresh session carrying `instructions`, with
    /// `tools` mounted. The protocol default drops the tools.
    ///
    /// - Parameters:
    ///   - instructions: The session's system instructions, or `nil`.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A live backend over ``model``.
    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            model: model,
            generationQueue: generationQueue,
            contextWindow: contextWindow,
            instructions: instructions,
            tools: tools
        )
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with no
    /// tools mounted.
    ///
    /// - Parameter transcript: The transcript to seed the session from.
    /// - Returns: A live backend over ``model``.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    /// Vends a backend over a fresh session seeded from `transcript`, with
    /// `tools` mounted.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to seed the session from.
    ///   - tools: The tools to mount on the session.
    /// - Returns: A live backend over ``model``.
    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            model: model,
            generationQueue: generationQueue,
            contextWindow: contextWindow,
            transcript: transcript,
            tools: tools
        )
    }
}
