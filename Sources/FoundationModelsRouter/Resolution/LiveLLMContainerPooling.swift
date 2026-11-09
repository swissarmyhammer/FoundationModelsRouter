import Foundation
import FoundationModels
import FoundationModelsLlamaCpp
import MLXFoundationModels
import MLXLMCommon

extension LiveLLMContainer {
    /// The file name of the model configuration in a model directory.
    private static let modelConfigurationFileName = "config.json"

    /// Wraps the generation model that a loader made in a live container:
    /// the Extras `MLXModelLoader` makes an `MLXLanguageModel`, and the Extras
    /// `LlamaCppModelLoader` makes a `LlamaLanguageModel`. The container counts
    /// tokens with the tokenizer that the model loaded with (see
    /// ``TokenCounter``).
    ///
    /// - Parameters:
    ///   - loaded: What the loader gave for a generation key.
    ///   - ref: The model reference of `loaded`. An error names its
    ///     repository id.
    /// - Returns: The container, or `nil` when `loaded` is no model that a
    ///   live container wraps.
    /// - Throws: The error of the wrap of the model.
    package static func make(wrappingLoaded loaded: any Sendable, ref: ModelRef) async throws -> LiveLLMContainer? {
        switch loaded {
        case let model as MLXLanguageModel: try await make(wrapping: model, ref: ref)
        case let model as LlamaLanguageModel: try make(wrapping: model, ref: ref)
        default: nil
        }
    }

    /// The wrapped model as an `MLXLanguageModel`, or `nil` for a model of
    /// another backend. The real-model test support evicts and inspects the
    /// MLX model through it.
    package var mlxModel: MLXLanguageModel? { model as? MLXLanguageModel }

    /// Wraps a `LlamaLanguageModel`. Its window is the context the model
    /// loaded at, which llama.cpp fixes at load, and it counts with the
    /// vocabulary of the model (``LlamaTokenCounter``).
    ///
    /// - Parameters:
    ///   - model: The model to wrap.
    ///   - ref: The model reference of `model`.
    /// - Returns: The container.
    /// - Throws: The error of the load of the vocabulary of the model.
    package static func make(wrapping model: LlamaLanguageModel, ref: ModelRef) throws -> LiveLLMContainer {
        LiveLLMContainer(
            model: model, ref: ref, contextWindow: model.contextSize,
            tokenCounter: LlamaTokenCounter(tokenizer: try model.tokenizer()))
    }

    /// Wraps an `MLXLanguageModel`. Its window is the native max context of
    /// the model.
    ///
    /// The model loads its weights here when it did not load them before. A
    /// model that the loader preloaded gives its loaded container at once.
    ///
    /// - Parameters:
    ///   - model: The model to wrap.
    ///   - ref: The model reference of `model`. An error names its
    ///     repository id.
    /// - Returns: The container.
    /// - Throws: The error of the load of the model, or of the read of its
    ///   window (``contextWindow(of:repo:)``).
    package static func make(wrapping model: MLXLanguageModel, ref: ModelRef) async throws -> LiveLLMContainer {
        let loaded = try await model.loadContainer()
        let tokenizer = await loaded.tokenizer
        let contextWindow = try await contextWindow(of: loaded, repo: ref.repo)
        return LiveLLMContainer(
            model: model, ref: ref, contextWindow: contextWindow,
            tokenCounter: TokenizerTokenCounter(tokenizer: tokenizer))
    }

    /// Reads the window of a loaded model: the native max context that the
    /// `config.json` in its local model directory declares.
    ///
    /// - Parameters:
    ///   - container: The loaded MLX container. Its configuration names the
    ///     local model directory.
    ///   - repo: The repository id the error names.
    /// - Returns: The native max context of the model, unchanged.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   configuration names no local directory or `config.json` declares no
    ///   positive context length, or the error of the file read.
    private static func contextWindow(of container: ModelContainer, repo: String) async throws -> Int {
        guard case .directory(let directory) = await container.configuration.id else {
            throw RepoMetadataError.metadataUnavailable(
                "the loaded model \(repo) names no local model directory")
        }
        let configJSON = try Data(
            contentsOf: directory.appendingPathComponent(modelConfigurationFileName, isDirectory: false))
        return try RepoMetadata.nativeMaxContext(configJSON: configJSON, repo: repo)
    }
}

/// The live generation container as a FoundationModels `LanguageModel`.
///
/// The Extras model pool gives the container of the first loader of a key to
/// each hold of that key. A `PooledModel` of the Extras pool uses an `.llm`
/// container as a `LanguageModel` (the contract of `PooledSession`). Thus the
/// container that a router load puts into the pool is a `LanguageModel` too,
/// and a `PooledModel` with the same name makes its sessions over the model
/// of the router. Each call goes to the executor of ``model`` unchanged.
extension LiveLLMContainer: FoundationModels.LanguageModel {
    /// The capabilities of ``model``, unchanged.
    package var capabilities: LanguageModelCapabilities { model.capabilities }

    /// The executor cache key: the key of ``model``. Two containers over one
    /// model share one executor.
    package var executorConfiguration: Executor.Configuration {
        Executor.Configuration(model: model)
    }

    /// The executor of a session over the container: it runs each pass on the
    /// executor of the wrapped model.
    package struct Executor: LanguageModelExecutor {
        /// The executor cache key. It compares by the executor configuration
        /// of the wrapped model.
        package struct Configuration: Sendable, Hashable {
            /// The wrapped model, whose executor runs each pass.
            let model: any FoundationModels.LanguageModel

            /// The executor configuration of ``model``, type-erased. Two
            /// configurations are equal when their models have one.
            private let modelConfiguration: any Hashable & Sendable

            /// Makes the configuration of a container over `model`.
            ///
            /// - Parameter model: The wrapped model.
            init(model: any FoundationModels.LanguageModel) {
                self.model = model
                modelConfiguration = model.executorConfiguration
            }

            /// Equality on the executor configuration of the wrapped models.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both wrapped models have one executor
            ///   configuration.
            package static func == (lhs: Self, rhs: Self) -> Bool {
                AnyHashable(lhs.modelConfiguration) == AnyHashable(rhs.modelConfiguration)
            }

            /// Hashes the executor configuration of the wrapped model.
            ///
            /// - Parameter hasher: The hasher to feed.
            package func hash(into hasher: inout Hasher) {
                hasher.combine(AnyHashable(modelConfiguration))
            }
        }

        /// The model type this executor serves.
        package typealias Model = LiveLLMContainer

        /// The executor of the wrapped model, made one time.
        private let innerRespond: ExecutorPassthrough.Respond

        /// Makes the executor of the wrapped model one time.
        ///
        /// - Parameter configuration: The wrapped model.
        /// - Throws: What the initializer of the wrapped executor throws.
        package init(configuration: Configuration) throws {
            innerRespond = try ExecutorPassthrough.make(wrapping: configuration.model)
        }

        /// Runs one pass on the executor of the wrapped model, with the
        /// request and the channel of the SDK unchanged.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: This container. Unread: the wrapped model arrives
        ///     through the configuration.
        ///   - channel: The channel the pass streams into.
        /// - Throws: What the wrapped executor throws.
        package func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: LiveLLMContainer,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await innerRespond(request, channel)
        }
    }
}
