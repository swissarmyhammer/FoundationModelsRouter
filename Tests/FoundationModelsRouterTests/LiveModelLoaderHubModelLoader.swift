import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

extension LiveModelLoader {
    /// The Extras `HubModelLoader` that the public init of this live loader
    /// made. The suites that prove what the public init gives to the Extras
    /// loader — the cache folder, the token provider — read it here.
    ///
    /// - Returns: Its `HubModelLoader`.
    /// - Throws: When the model loader is not a `HubModelLoader`, which
    ///   means that a test init made the live loader.
    func requireHubModelLoader() throws -> HubModelLoader {
        try #require(modelLoader as? HubModelLoader)
    }

    /// The `MLXModelLoader` inside the `HubModelLoader` of this live loader.
    /// It loads each `.llm` key, and each `.embedding` key of a repository
    /// with `safetensors` weights.
    ///
    /// The `HubModelLoader` keeps its two loaders private, and a test that
    /// proves what the public init gives to a loader needs the loader itself,
    /// so this reads the stored property by its name.
    ///
    /// - Returns: Its `MLXModelLoader`.
    /// - Throws: When the model loader is not a `HubModelLoader`, or when it
    ///   has no stored `MLXModelLoader` named `mlx`.
    func requireMLXModelLoader() throws -> MLXModelLoader {
        try Self.storedLoader(named: "mlx", in: requireHubModelLoader())
    }

    /// The `CoreMLModelLoader` inside the `HubModelLoader` of this live
    /// loader. It loads each `.embedding` key of a repository with a
    /// `.mlpackage` folder. See ``requireMLXModelLoader()``.
    ///
    /// - Returns: Its `CoreMLModelLoader`.
    /// - Throws: When the model loader is not a `HubModelLoader`, or when it
    ///   has no stored `CoreMLModelLoader` named `coreML`.
    func requireCoreMLModelLoader() throws -> CoreMLModelLoader {
        try Self.storedLoader(named: "coreML", in: requireHubModelLoader())
    }

    /// Reads one stored loader of a `HubModelLoader` by the name of its
    /// property.
    private static func storedLoader<Loader>(named name: String, in hub: HubModelLoader) throws -> Loader {
        let child = Mirror(reflecting: hub).children.first { $0.label == name }
        return try #require(child?.value as? Loader)
    }
}
