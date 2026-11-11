import Foundation
import FoundationModelsDecision
import Testing

@testable import FoundationModelsRouter

/// Tests of ``DecisionFormatLoader``: the prompt format of a decision model
/// comes from the `decider_config.json` file of its repository, which the
/// metadata source reads at the revision of the reference (decision D13). No
/// network: a stub source answers each read.
@Suite("The prompt format of a decision model, from its repository")
struct DecisionFormatLoaderTests {
    /// One read of a file that the stub source answered.
    struct FileFetch: Equatable {
        /// The repository of the read.
        let repo: String

        /// The revision of the read.
        let revision: String?

        /// The path of the file in the repository.
        let path: String
    }

    /// A ``MetadataSource`` that answers each file read from fixed bytes, by
    /// the path of the file, and records each read.
    actor RecordingFileSource: MetadataSource {
        /// A read of a file the source does not hold.
        struct MissingFile: Error {}

        /// The bytes of each file, by its path in the repository.
        private let files: [String: Data]

        /// Each file read, in the order of the reads.
        private(set) var fetches: [FileFetch] = []

        /// Makes a source.
        ///
        /// - Parameter files: The bytes of each file, by its path in the repository.
        init(files: [String: Data]) {
            self.files = files
        }

        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            throw MissingFile()
        }

        func fetchFileBytes(repo: String, revision: String?, path: String, range: Range<Int>) async throws -> Data {
            fetches.append(FileFetch(repo: repo, revision: revision, path: path))
            guard let bytes = files[path] else { throw MissingFile() }
            return bytes.subdata(in: range.clamped(to: 0..<bytes.count))
        }
    }

    /// The name of the configuration file of a decider repository.
    private static let configurationFileName = "decider_config.json"

    /// The repository of the tests on the Hub.
    private static let repo = "org/decider"

    /// A full commit id that the reference pins.
    private static let commitHash = "0f1e2d3c4b5a69788796a5b4c3d2e1f009182736"

    /// The temperature of the fixture configuration.
    private static let fixtureTemperature = 0.3

    /// A small `decider_config.json` file.
    private static let deciderConfigJSON = Data("""
        {"layout": "plain", "temperature": \(fixtureTemperature), "isolated_levels": false}
        """.utf8)

    /// Data that is not JSON.
    private static let malformedJSON = Data("this is not JSON".utf8)

    /// A `config.json` with a small attention shape, so that the repository
    /// sizes as an MLX model.
    private static let modelConfigJSON = Data("""
        {
            "num_hidden_layers": 2,
            "num_attention_heads": 8,
            "head_dim": 16,
            "max_position_embeddings": 4096
        }
        """.utf8)

    /// The size of the weights of the repository.
    private static let weightBytes: Int64 = 1_000

    /// The configuration that the fixture file gives.
    ///
    /// - Returns: The decoded configuration.
    /// - Throws: The error of the decode.
    private static func expectedConfiguration() throws -> DeciderConfiguration {
        try JSONDecoder().decode(DeciderConfiguration.self, from: deciderConfigJSON)
    }

    /// The metadata of a repository whose tree listing has, or does not have,
    /// a `decider_config.json` file of a size.
    ///
    /// - Parameter configurationBytes: The bytes of the configuration file,
    ///   or `nil` for a repository with no such file.
    /// - Returns: The metadata.
    /// - Throws: The error of the parse.
    private static func metadata(configurationBytes: Data?) throws -> RepoMetadata {
        let weights = HubTreeListing.Entry.file("model.safetensors", size: weightBytes)
        let configuration = configurationBytes.map { HubTreeListing.Entry.file(configurationFileName, size: Int64($0.count)) }
        let tree = HubTreeListing.json([weights] + (configuration.map { [$0] } ?? []))
        return try RepoMetadata(raw: RawRepoMetadata(configJSON: modelConfigJSON, treeJSON: tree), repo: repo)
    }

    /// Selects the format of a Hub reference over a stub source.
    ///
    /// - Parameters:
    ///   - ref: The reference.
    ///   - configurationBytes: The bytes of the configuration file, or `nil`
    ///     for a repository with no such file.
    /// - Returns: The format and the source.
    /// - Throws: The error of the selection.
    private static func select(
        ref: ModelRef, configurationBytes: Data?
    ) async throws -> (format: any DecisionPromptFormat, source: RecordingFileSource) {
        let source = RecordingFileSource(files: configurationBytes.map { [configurationFileName: $0] } ?? [:])
        let format = try await DecisionFormatLoader.format(
            for: ref, metadata: metadata(configurationBytes: configurationBytes), source: source)
        return (format, source)
    }

    @Test("a repository with decider_config.json gives DeciderPromptFormat with the configuration of the file")
    func configurationGivesDeciderFormat() async throws {
        let (format, _) = try await Self.select(ref: ModelRef(repo: Self.repo), configurationBytes: Self.deciderConfigJSON)

        #expect((format as? DeciderPromptFormat)?.configuration == (try Self.expectedConfiguration()))
    }

    @Test("decider_config.json is read at the revision of the reference")
    func fetchUsesRevisionOfReference() async throws {
        let ref = ModelRef(repo: Self.repo, revision: Self.commitHash)
        let (_, source) = try await Self.select(ref: ref, configurationBytes: Self.deciderConfigJSON)

        #expect(
            await source.fetches
                == [FileFetch(repo: Self.repo, revision: Self.commitHash, path: Self.configurationFileName)])
    }

    @Test("a repository with no decider_config.json gives GenericPromptFormat")
    func noConfigurationGivesGenericFormat() async throws {
        let (format, _) = try await Self.select(ref: ModelRef(repo: Self.repo), configurationBytes: nil)

        #expect(format is GenericPromptFormat)
    }

    @Test("a repository with no decider_config.json reads no file")
    func noConfigurationReadsNoFile() async throws {
        let (_, source) = try await Self.select(ref: ModelRef(repo: Self.repo), configurationBytes: nil)

        #expect(await source.fetches.isEmpty)
    }

    @Test("a malformed decider_config.json throws a DecodingError")
    func malformedConfigurationThrows() async throws {
        await #expect(throws: DecodingError.self) {
            try await Self.select(ref: ModelRef(repo: Self.repo), configurationBytes: Self.malformedJSON)
        }
    }

    @Test("a failed read of decider_config.json throws the error of the source")
    func failedReadThrows() async throws {
        let source = RecordingFileSource(files: [:])
        let metadata = try Self.metadata(configurationBytes: Self.deciderConfigJSON)

        await #expect(throws: RecordingFileSource.MissingFile.self) {
            try await DecisionFormatLoader.format(for: ModelRef(repo: Self.repo), metadata: metadata, source: source)
        }
    }

    @Test("a local model folder with decider_config.json gives DeciderPromptFormat with the configuration of the file")
    func localFolderGivesDeciderFormat() async throws {
        let folder = try TempModelFolder(prefix: "DecisionFormatLoaderTests-local")
        defer { folder.remove() }
        try folder.write("model.gguf", data: GGUFHeaderFixtures.denseBytes)
        try folder.write(Self.configurationFileName, data: Self.deciderConfigJSON)
        let metadata = try await RepoMetadata(localLocation: folder.url)

        let format = try await DecisionFormatLoader.format(
            for: ModelRef(repo: folder.url.path), metadata: metadata, source: RecordingFileSource(files: [:]))

        #expect((format as? DeciderPromptFormat)?.configuration == (try Self.expectedConfiguration()))
    }
}
