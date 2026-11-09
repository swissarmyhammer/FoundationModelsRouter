import FoundationModelsExtrasLlamaCpp
import HuggingFace
import Testing

@testable import FoundationModelsExtras

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

    /// The `LlamaCppModelLoader` inside the `HubModelLoader` of this live
    /// loader. It loads each `.llm` key whose files are GGUF. See
    /// ``requireMLXModelLoader()``.
    ///
    /// - Returns: Its `LlamaCppModelLoader`.
    /// - Throws: When the model loader is not a `HubModelLoader`, or when its
    ///   optional GGUF loader named `gguf` is absent or of another type.
    func requireGGUFModelLoader() throws -> LlamaCppModelLoader {
        try Self.storedLoader(named: "gguf", in: requireHubModelLoader())
    }

    /// The `HubClient` that the GGUF loader of this live loader downloads
    /// with. The source keeps its `HubSource` private, so this reads it by its
    /// name.
    ///
    /// - Returns: The client of each GGUF download.
    /// - Throws: When a stored property is missing or of another type.
    func requireGGUFHubClient() throws -> HubClient {
        let hub: HubSource = try Self.stored(named: "hub", in: requireGGUFSource())
        return hub.client()
    }

    /// The `GGUFSource` of the GGUF loader of this live loader: the cache it
    /// downloads to and reads the files from. See ``requireGGUFHubClient()``.
    ///
    /// - Returns: The source of each GGUF model.
    /// - Throws: When a stored property is missing or of another type.
    func requireGGUFSource() throws -> GGUFSource {
        try Self.stored(named: "source", in: requireGGUFModelLoader())
    }

    /// Reads one stored loader of a `HubModelLoader` by the name of its
    /// property.
    private static func storedLoader<Loader>(named name: String, in hub: HubModelLoader) throws -> Loader {
        try stored(named: name, in: hub)
    }

    /// Reads one stored property of `value` by its name. An optional property
    /// that holds a value casts to its wrapped type.
    private static func stored<Value>(named name: String, in value: Any) throws -> Value {
        let child = Mirror(reflecting: value).children.first { $0.label == name }
        return try #require(child?.value as? Value)
    }
}
