import Foundation
import FoundationModelsRouterTestSupport
import MLXFoundationModels
import MLXLMCommon

@testable import FoundationModelsRouter

/// An `MLXLanguageModel` whose load always fails, and a live container over
/// it. A test that needs the real MLX types, but no weights, uses them. A
/// session over the model can exist, but no test may load the model: a load
/// sets the MLX memory limit first, and that needs the metal library, which a
/// unit test does not have.
enum UnloadableMLXModel {
    /// The window that ``liveContainer(repo:)`` declares.
    static let contextWindow = 4096

    /// The error that each load of the model throws.
    private static let loadError = ModelLoaderError.notConfigured

    /// Makes an `MLXLanguageModel` of `repo` whose load throws ``loadError``.
    ///
    /// - Parameter repo: The repository id of the model.
    /// - Returns: The model.
    static func make(repo: String) -> MLXLanguageModel {
        MLXLanguageModel(
            configuration: ModelConfiguration(id: repo),
            weightsLocation: { _ in FileManager.default.temporaryDirectory },
            load: { _, _ in throw loadError })
    }

    /// Makes a live container over ``make(repo:)``, with a counter of one
    /// token for each character.
    ///
    /// - Parameter repo: The repository id of the model.
    /// - Returns: The container.
    static func liveContainer(repo: String) -> MLXFoundationModelsContainer {
        MLXFoundationModelsContainer(
            model: make(repo: repo), contextWindow: contextWindow, tokenCounter: CharacterTokenCounter())
    }
}
