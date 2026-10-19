import FoundationModels
import FoundationModelsRouter

/// A scripted container whose sessions get their tools with the tool hook
/// layer of Router, as the live model loader gives them.
///
/// Router puts the tool hook layer on the tools of a session in the live
/// backend of `LiveModelLoader` only. A scripted container (the scripted
/// model of a host, for example) calls its tools directly. Thus with a
/// scripted container, a tool call sends no `PreToolUse`, `PreToolResult` and
/// `PostToolUse`. A host test puts its scripted container in this container
/// to see the tool events with a scripted model:
///
/// ```swift
/// let container = HookLayeredLLMContainer(wrapping: scriptedContainer)
/// ```
///
/// This container gives each tool of each session the layers of the live
/// backend, through the same code path: the no-op check and the repetition
/// check outermost, then the hook layer, then the failure delivery of the
/// mount. It does the same for the tools of each fork of a session, as the
/// live backend does. A block on `PreToolUse` thus does not run the tool
/// body, and a tool body that throws gives `PostToolUse` with
/// `succeeded: false`.
///
/// Wrap only a container whose backends call the tools that they get. Do not
/// wrap a container whose backends put the layer on by themselves (a live
/// container): each tool then has the layer two times, and each tool call
/// sends each event two times.
public struct HookLayeredLLMContainer: LoadedLLMContainer {
    /// The scripted container that makes the backends.
    private let wrapped: any LoadedLLMContainer

    /// Makes a container that puts the tool hook layer on the tools of each
    /// session of `wrapped`.
    ///
    /// - Parameter wrapped: The scripted container that makes the backends.
    public init(wrapping wrapped: any LoadedLLMContainer) {
        self.wrapped = wrapped
    }

    /// The counter of the wrapped container.
    public var tokenCounter: any TokenCounter { wrapped.tokenCounter }

    /// This container over the copy of the wrapped container whose backends
    /// name `queue`.
    ///
    /// - Parameter queue: The work queue of the pool entry of the model.
    /// - Returns: The container over the copy.
    public func submitting(to queue: GenerationQueue) -> any LoadedLLMContainer {
        HookLayeredLLMContainer(wrapping: wrapped.submitting(to: queue))
    }

    /// A backend of the wrapped container with no tools.
    ///
    /// - Parameter instructions: The session instructions, or `nil`.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeSession(instructions: instructions))
    }

    /// A backend of the wrapped container whose tools have the layer.
    ///
    /// - Parameters:
    ///   - instructions: The session instructions, or `nil`.
    ///   - tools: The tools of the session.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(
            wrapping: wrapped.makeSession(instructions: instructions, tools: SessionToolLayers.checked(tools)))
    }

    /// A restored backend of the wrapped container with no tools.
    ///
    /// - Parameter transcript: The transcript of the restored session.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeSession(transcript: transcript))
    }

    /// A restored backend of the wrapped container whose tools have the
    /// layer.
    ///
    /// - Parameters:
    ///   - transcript: The transcript of the restored session.
    ///   - tools: The tools of the session.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(
            wrapping: wrapped.makeSession(transcript: transcript, tools: SessionToolLayers.checked(tools)))
    }

    /// A backend of the wrapped container with no tools, that decodes with
    /// `samplingMode`.
    ///
    /// - Parameters:
    ///   - instructions: The session instructions, or `nil`.
    ///   - samplingMode: The decoding strategy, or `nil` for the default of
    ///     the wrapped container.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(
        instructions: String?, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeSession(instructions: instructions, samplingMode: samplingMode))
    }

    /// A backend of the wrapped container whose tools have the layer, that
    /// decodes with `samplingMode`.
    ///
    /// - Parameters:
    ///   - instructions: The session instructions, or `nil`.
    ///   - tools: The tools of the session.
    ///   - samplingMode: The decoding strategy, or `nil` for the default of
    ///     the wrapped container.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(
        instructions: String?, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(
            wrapping: wrapped.makeSession(
                instructions: instructions, tools: SessionToolLayers.checked(tools), samplingMode: samplingMode
            ))
    }

    /// A restored backend of the wrapped container with no tools, that
    /// decodes with `samplingMode`.
    ///
    /// - Parameters:
    ///   - transcript: The transcript of the restored session.
    ///   - samplingMode: The decoding strategy, or `nil` for the default of
    ///     the wrapped container.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(
        transcript: Transcript, samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeSession(transcript: transcript, samplingMode: samplingMode))
    }

    /// A restored backend of the wrapped container whose tools have the
    /// layer, that decodes with `samplingMode`.
    ///
    /// - Parameters:
    ///   - transcript: The transcript of the restored session.
    ///   - tools: The tools of the session.
    ///   - samplingMode: The decoding strategy, or `nil` for the default of
    ///     the wrapped container.
    /// - Returns: The backend, which puts the layer on the tools of each fork.
    public func makeSession(
        transcript: Transcript, tools: [any Tool], samplingMode: GenerationOptions.SamplingMode?
    ) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(
            wrapping: wrapped.makeSession(
                transcript: transcript, tools: SessionToolLayers.checked(tools), samplingMode: samplingMode))
    }
}

/// A backend of a ``HookLayeredLLMContainer``: the backend of the wrapped
/// container, which puts the tool hook layer on the tools of each fork.
///
/// A session forks its backend with the tools of the fork
/// (`makeFork(tools:seededFrom:)`), and the live backend puts the layer on
/// those tools. This backend does the same. Each other call goes to the
/// wrapped backend. Each backend that a call makes (a fork, a replaced
/// transcript) is in this decorator too, so a fork of a fork also gets the
/// layer.
final class HookLayeredSessionBackend: LanguageModelSessionBackend {
    /// The backend of the wrapped container.
    private let wrapped: any LanguageModelSessionBackend

    /// Makes a backend over `wrapped`.
    ///
    /// - Parameter wrapped: The backend of the wrapped container.
    init(wrapping wrapped: any LanguageModelSessionBackend) {
        self.wrapped = wrapped
    }

    /// The work queue of the wrapped backend.
    var generationQueue: GenerationQueue? { wrapped.generationQueue }

    /// Generates a complete text response through the wrapped backend.
    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await wrapped.respond(to: prompt, maxTokens: maxTokens)
    }

    /// Generates a complete text response with reasoning off through the
    /// wrapped backend.
    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        try await wrapped.respondWithoutReasoning(to: prompt, maxTokens: maxTokens)
    }

    /// Streams a text response through the wrapped backend.
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        wrapped.streamResponse(to: prompt, maxTokens: maxTokens)
    }

    /// Streams a text response as fragments through the wrapped backend.
    func streamResponseFragments(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<ResponseFragment, Error> {
        wrapped.streamResponseFragments(to: prompt, maxTokens: maxTokens)
    }

    /// Generates a constrained text response through the wrapped backend.
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await wrapped.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    /// A fork of the wrapped backend, with the tools that it has.
    func makeFork() -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeFork())
    }

    /// A fork of the wrapped backend whose tools have the layer.
    ///
    /// - Parameter tools: The tools of the fork.
    /// - Returns: The fork, in this decorator.
    func makeFork(tools: [any Tool]) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.makeFork(tools: SessionToolLayers.checked(tools)))
    }

    /// A fork of the wrapped backend, seeded from `transcript`, whose tools
    /// have the layer.
    ///
    /// - Parameters:
    ///   - tools: The tools of the fork.
    ///   - transcript: The transcript to seed the fork from.
    /// - Returns: The fork, in this decorator.
    func makeFork(tools: [any Tool], seededFrom transcript: Transcript) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(
            wrapping: wrapped.makeFork(tools: SessionToolLayers.checked(tools), seededFrom: transcript))
    }

    /// The transcript of the wrapped backend.
    func transcriptEntries() -> [Transcript.Entry] {
        wrapped.transcriptEntries()
    }

    /// The token usage of the wrapped backend.
    func usageTokenCounts() -> (input: Int, output: Int)? {
        wrapped.usageTokenCounts()
    }

    /// The output token count of the last generation call of the wrapped
    /// backend.
    func lastGenerationCallOutputTokenCount() -> Int? {
        wrapped.lastGenerationCallOutputTokenCount()
    }

    /// The response in flight of the wrapped backend.
    func inFlightResponse() -> InFlightResponse? {
        wrapped.inFlightResponse()
    }

    /// The transcript updates of the wrapped backend.
    func transcriptUpdates() -> AsyncStream<[Transcript.Entry]> {
        wrapped.transcriptUpdates()
    }

    /// A backend of the wrapped backend seeded from `transcript`, with the
    /// tools that it has.
    ///
    /// - Parameter transcript: The transcript to seed the backend from.
    /// - Returns: The backend, in this decorator.
    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        HookLayeredSessionBackend(wrapping: wrapped.replacingTranscript(transcript))
    }
}
