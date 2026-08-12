import FoundationModels

@testable import FoundationModelsRouter

/// A minimal `LanguageModel` conformer satisfying
/// ``LoadedLLMContainer/languageModel``'s requirement — never actually
/// driven: suites use it when a test only calls
/// ``RecordingLanguageModel/sync(_:usage:)`` or
/// ``RecordingLanguageModel/noteCompaction(_:)`` directly with a fabricated
/// transcript rather than driving a real `LanguageModelSession` turn.
struct UndrivenLanguageModel: LanguageModel {
    /// The empty capability set — a stand-in that is never driven advertises
    /// no capabilities.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }
    /// The empty configuration the trapping ``Executor`` is constructed with.
    var executorConfiguration: Executor.Configuration { Executor.Configuration() }

    /// The executor conformance `LanguageModel` requires — trapping on any
    /// real generation, since this stand-in is never driven.
    struct Executor: LanguageModelExecutor {
        /// The empty cache-key configuration the SDK constructs this
        /// executor with.
        struct Configuration: Sendable, Hashable {}
        /// The model this executor serves.
        typealias Model = UndrivenLanguageModel

        /// Creates the executor; the empty configuration carries no data.
        init(configuration: Configuration) throws {}

        /// Traps unconditionally — this stand-in is never driven, so a real
        /// generation call is a test error.
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
    /// Creates a stub session backend.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        StubSessionBackend()
    }

    /// An undriven stub language model.
    var languageModel: any LanguageModel { UndrivenLanguageModel() }
}
