import Foundation
import FoundationModels
import MLXFoundationModels
import MLXLMCommon

extension MLXFoundationModelsContainer {
    /// The file name of the model configuration in a model directory.
    private static let modelConfigurationFileName = "config.json"

    /// Wraps a model that a loader made, for example the Extras
    /// `MLXModelLoader`, in a live container. The container counts tokens
    /// with the tokenizer that the model loaded with (see ``TokenCounter``),
    /// and its window is the native max context of the model.
    ///
    /// The model loads its weights here when it did not load them before. A
    /// model that the loader preloaded gives its loaded container at once.
    ///
    /// - Parameters:
    ///   - model: The model to wrap.
    ///   - repo: The repository id of the model, which an error names.
    /// - Returns: A container that names no queue. The router gives it the
    ///   queue of the pool entry through ``submitting(to:)``.
    /// - Throws: The error of the load of the model, or of the read of its
    ///   window (``contextWindow(of:repo:)``).
    package static func make(wrapping model: MLXLanguageModel, repo: String) async throws -> MLXFoundationModelsContainer {
        let loaded = try await model.loadContainer()
        let tokenizer = await loaded.tokenizer
        let contextWindow = try await contextWindow(of: loaded, repo: repo)
        return MLXFoundationModelsContainer(
            model: model, contextWindow: contextWindow, tokenCounter: TokenizerTokenCounter(tokenizer: tokenizer))
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
extension MLXFoundationModelsContainer: FoundationModels.LanguageModel {
    /// The capabilities of ``model``, unchanged.
    package var capabilities: LanguageModelCapabilities { model.capabilities }

    /// The executor cache key: the key of ``model``. Two containers over one
    /// model share one executor.
    package var executorConfiguration: Executor.Configuration {
        Executor.Configuration(model: model)
    }

    /// The executor of a session over the container: it runs each pass on the
    /// executor of the wrapped `MLXLanguageModel`.
    package struct Executor: LanguageModelExecutor {
        /// The executor cache key. It compares by the executor configuration
        /// of the wrapped model.
        package struct Configuration: Sendable, Hashable {
            /// The wrapped model, whose executor runs each pass.
            let model: MLXLanguageModel

            /// Equality on the executor configuration of the wrapped models.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both wrapped models have one executor
            ///   configuration.
            package static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.model.executorConfiguration == rhs.model.executorConfiguration
            }

            /// Hashes the executor configuration of the wrapped model.
            ///
            /// - Parameter hasher: The hasher to feed.
            package func hash(into hasher: inout Hasher) {
                hasher.combine(model.executorConfiguration)
            }
        }

        /// The model type this executor serves.
        package typealias Model = MLXFoundationModelsContainer

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
            model: MLXFoundationModelsContainer,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            try await innerRespond(request, channel)
        }
    }
}
