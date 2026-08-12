import FoundationModels

@testable import FoundationModelsRouter

/// A minimal `LanguageModel` conformer satisfying
/// ``LoadedLLMContainer/languageModel``'s requirement — never actually
/// driven: suites use it when a test only calls
/// ``RecordingLanguageModel/sync(_:usage:)`` or
/// ``RecordingLanguageModel/noteCompaction(_:)`` directly with a fabricated
/// transcript rather than driving a real `LanguageModelSession` turn.
struct UndrivenLanguageModel: LanguageModel {
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    var executorConfiguration: Executor.Configuration { Executor.Configuration() }

    /// The executor conformance `LanguageModel` requires — trapping on any
    /// real generation, since this stand-in is never driven.
    struct Executor: LanguageModelExecutor {
        /// The empty cache-key configuration the SDK constructs this
        /// executor with.
        struct Configuration: Sendable, Hashable {}
        typealias Model = UndrivenLanguageModel

        init(configuration: Configuration) throws {}

        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: UndrivenLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            fatalError("UndrivenLanguageModel.Executor.respond: never driven")
        }
    }
}

/// A ``PlainTranscriptStubContainer`` whose ``LoadedLLMContainer/languageModel``
/// is an ``UndrivenLanguageModel`` — for suites that mint a bare
/// ``RecordingLanguageModel`` handle via ``RoutedModel/makeLanguageModel()``
/// and drive it only through direct `sync`/`noteCompaction` calls.
struct UndrivenLanguageModelContainer: PlainTranscriptStubContainer {
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        StubSessionBackend()
    }

    var languageModel: any LanguageModel { UndrivenLanguageModel() }
}
