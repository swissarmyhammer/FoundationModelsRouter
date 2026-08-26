import CryptoKit
import Foundation
import os

/// The raw bytes of the two Hub artifacts that sizing needs. No weights are downloaded.
public struct RawRepoMetadata: Sendable {
    /// The bytes of `config.json` at the revision, or `nil` when absent.
    public let configJSON: Data?

    /// The bytes of the repo tree listing JSON (`…/tree/{rev}`).
    public let treeJSON: Data

    /// Creates a raw metadata bundle.
    public init(configJSON: Data?, treeJSON: Data) {
        self.configJSON = configJSON
        self.treeJSON = treeJSON
    }
}

/// The fetch behind ``RepoMetadataReader``. The live implementation is ``HuggingFaceMetadataSource``.
public protocol MetadataSource: Sendable {
    /// Fetches the raw `config.json` and tree listing for a repo at a revision.
    ///
    /// - Parameters:
    ///   - repo: The Hugging Face repository id, e.g. `"org/repo"`.
    ///   - revision: The pinned revision, or `nil` for the default revision.
    /// - Throws: If the transport fails.
    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata
}

/// A failure reading a repo's sizing metadata.
public enum RepoMetadataError: Error, Equatable {
    /// The repo cannot be sized; the associated value explains why.
    case metadataUnavailable(String)
}

/// The parsed sizing metadata for one repo at one revision: the resident weight
/// bytes and the attention architecture needed for the KV-cache math.
///
/// The GQA and head-dim fallbacks are not applied here; ``Footprint`` applies them.
public struct RepoMetadata: Sendable, Equatable, Codable {
    /// Resident weight bytes — `Σ size(*.safetensors)`.
    public let weightBytes: Int64

    /// Transformer layer count (`num_hidden_layers`).
    public let numHiddenLayers: Int

    /// Query head count (`num_attention_heads`).
    public let numAttentionHeads: Int

    /// Key/value head count (`num_key_value_heads`); `nil` for multi-head attention.
    public let numKeyValueHeads: Int?

    /// Per-head dimension (`head_dim`); `nil` when the config omits it.
    public let headDim: Int?

    /// Model hidden size (`hidden_size`); used to derive `headDim` when absent.
    public let hiddenSize: Int?

    /// Number of layers whose KV cache grows with context.
    ///
    /// Equal to `numHiddenLayers` unless the config declares `layer_types`; then it
    /// is the count of `"full_attention"` entries.
    public let numFullAttentionLayers: Int

    /// The model's native maximum context length, from `max_position_embeddings`,
    /// then `n_positions`, then `max_seq_len`, then `seq_length`.
    ///
    /// Defaults to ``defaultNativeMaxContext`` when none is present. Clamped to
    /// `[nativeMaxContextFloor, nativeMaxContextCap]`.
    public let nativeMaxContext: Int

    /// Why ``nativeMaxContext`` differs from the raw `config.json` value, or `nil`
    /// when it does not.
    public let nativeMaxContextDiagnostic: String?

    /// The ceiling that ``nativeMaxContext`` is capped to.
    public static let nativeMaxContextCap = 1_048_576

    /// The floor that ``nativeMaxContext`` is raised to.
    public static let nativeMaxContextFloor = 4096

    /// The native max context used when `config.json` has no context-length field.
    public static let defaultNativeMaxContext = 8192

    /// Creates parsed metadata from already-resolved values.
    ///
    /// `numFullAttentionLayers` defaults to `numHiddenLayers`. `nativeMaxContext`
    /// defaults to ``defaultNativeMaxContext``.
    public init(
        weightBytes: Int64,
        numHiddenLayers: Int,
        numAttentionHeads: Int,
        numKeyValueHeads: Int?,
        headDim: Int?,
        hiddenSize: Int?,
        numFullAttentionLayers: Int? = nil,
        nativeMaxContext: Int = RepoMetadata.defaultNativeMaxContext,
        nativeMaxContextDiagnostic: String? = nil
    ) {
        self.weightBytes = weightBytes
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.hiddenSize = hiddenSize
        self.numFullAttentionLayers = numFullAttentionLayers ?? numHiddenLayers
        self.nativeMaxContext = nativeMaxContext
        self.nativeMaxContextDiagnostic = nativeMaxContextDiagnostic
    }

    /// Parses sizing metadata from raw fetched artifacts.
    ///
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when `config.json`
    ///   is absent, does not parse, lacks required fields, or the tree has no `*.safetensors`.
    public init(raw: RawRepoMetadata) throws {
        guard let configJSON = raw.configJSON else {
            throw RepoMetadataError.metadataUnavailable("config.json is not present in the repo")
        }
        guard let config = try? JSONDecoder().decode(RepoConfig.self, from: configJSON) else {
            throw RepoMetadataError.metadataUnavailable("config.json could not be parsed")
        }
        guard let sizing = config.sizingSource else {
            throw RepoMetadataError.metadataUnavailable(
                "config.json is missing num_hidden_layers or num_attention_heads"
            )
        }
        guard sizing.headDim != nil || sizing.hiddenSize != nil else {
            throw RepoMetadataError.metadataUnavailable(
                "config.json has neither head_dim nor hidden_size to size a head"
            )
        }
        let weightBytes = try Self.residentWeightBytes(treeJSON: raw.treeJSON)
        // Hybrid linear/full-attention models (e.g. Qwen3.5's linear_attention
        // layers, a fixed-size recurrent state that does not grow with context)
        // declare layer_types; only its "full_attention" entries materialize a
        // growing KV cache. Absent layer_types (the common, non-hybrid case)
        // falls back to numHiddenLayers, preserving prior behavior.
        let numFullAttentionLayers = sizing.layerTypes?.filter { $0 == Self.fullAttentionLayerType }.count
            ?? sizing.numHiddenLayers
        let (nativeMaxContext, nativeMaxContextDiagnostic) = Self.resolveNativeMaxContext(
            raw: sizing.nativeMaxContextRaw
        )
        self.init(
            weightBytes: weightBytes,
            numHiddenLayers: sizing.numHiddenLayers,
            numAttentionHeads: sizing.numAttentionHeads,
            numKeyValueHeads: sizing.numKeyValueHeads,
            headDim: sizing.headDim,
            hiddenSize: sizing.hiddenSize,
            numFullAttentionLayers: numFullAttentionLayers,
            nativeMaxContext: nativeMaxContext,
            nativeMaxContextDiagnostic: nativeMaxContextDiagnostic
        )
    }

    /// Clamps the raw context-length figure and returns it with a diagnostic.
    ///
    /// - Returns: The clamped native max context, and why it differs from `raw` (`nil` when it does not).
    private static func resolveNativeMaxContext(raw: Int?) -> (Int, String?) {
        guard let raw else {
            return (
                Self.defaultNativeMaxContext,
                "config.json has none of max_position_embeddings, n_positions, max_seq_len, "
                    + "or seq_length; defaulting native max context to \(Self.defaultNativeMaxContext)"
            )
        }
        if raw > Self.nativeMaxContextCap {
            return (
                Self.nativeMaxContextCap,
                "config.json's native max context \(raw) exceeds the sanity cap of "
                    + "\(Self.nativeMaxContextCap); capping to \(Self.nativeMaxContextCap)"
            )
        }
        if raw < Self.nativeMaxContextFloor {
            return (
                Self.nativeMaxContextFloor,
                "config.json's native max context \(raw) is below the floor of "
                    + "\(Self.nativeMaxContextFloor); raising to \(Self.nativeMaxContextFloor)"
            )
        }
        return (raw, nil)
    }

    /// The memory footprint estimate for this repo. Uses ``numFullAttentionLayers``
    /// as the KV-cache layer count.
    public var footprint: Footprint {
        Footprint(
            weightBytes: weightBytes,
            numHiddenLayers: numFullAttentionLayers,
            numAttentionHeads: numAttentionHeads,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim,
            hiddenSize: hiddenSize
        )
    }

    /// Sums the sizes of every `*.safetensors` file in a tree listing. Prefers `lfs.size` over `size`.
    ///
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the sum is not positive.
    private static func residentWeightBytes(treeJSON: Data) throws -> Int64 {
        let entries = (try? JSONDecoder().decode([TreeEntry].self, from: treeJSON)) ?? []
        let total = entries
            .filter { $0.path.hasSuffix(Self.safetensorsSuffix) }
            .reduce(Int64(0)) { $0 + ($1.lfs?.size ?? $1.size ?? 0) }
        guard total > 0 else {
            throw RepoMetadataError.metadataUnavailable("no *.safetensors weight files in the repo tree")
        }
        return total
    }

    /// The file extension that marks a weight shard in the tree listing.
    private static let safetensorsSuffix = ".safetensors"

    /// The `layer_types` entry that marks a layer as full attention.
    private static let fullAttentionLayerType = "full_attention"

    /// The sizing fields resolved from one source (top level or `text_config`).
    /// Only ``SizingFields/resolved`` creates one, so the required fields are present.
    private struct ResolvedSizing {
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numKeyValueHeads: Int?
        let headDim: Int?
        let hiddenSize: Int?
        let layerTypes: [String]?

        /// The first native-max-context field present, or `nil` when none is.
        let nativeMaxContextRaw: Int?
    }

    /// The `config.json` fields that sizing needs, with their snake_case keys.
    /// Every field is optional; ``resolved`` enforces the required ones.
    private struct SizingFields: Decodable {
        let numHiddenLayers: Int?
        let numAttentionHeads: Int?
        let numKeyValueHeads: Int?
        let headDim: Int?
        let hiddenSize: Int?
        let layerTypes: [String]?

        /// `max_position_embeddings`: the first-priority native-max-context field.
        let maxPositionEmbeddings: Int?

        /// `n_positions`: the second-priority native-max-context field.
        let nPositions: Int?

        /// `max_seq_len`: the third-priority native-max-context field.
        let maxSeqLen: Int?

        /// `seq_length`: the last native-max-context field.
        let seqLength: Int?

        enum CodingKeys: String, CodingKey {
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case hiddenSize = "hidden_size"
            case layerTypes = "layer_types"
            case maxPositionEmbeddings = "max_position_embeddings"
            case nPositions = "n_positions"
            case maxSeqLen = "max_seq_len"
            case seqLength = "seq_length"
        }

        /// This field set as a ``ResolvedSizing``, or `nil` when `numHiddenLayers`
        /// or `numAttentionHeads` is absent.
        var resolved: ResolvedSizing? {
            guard let numHiddenLayers, let numAttentionHeads else { return nil }
            return ResolvedSizing(
                numHiddenLayers: numHiddenLayers,
                numAttentionHeads: numAttentionHeads,
                numKeyValueHeads: numKeyValueHeads,
                headDim: headDim,
                hiddenSize: hiddenSize,
                layerTypes: layerTypes,
                nativeMaxContextRaw: maxPositionEmbeddings ?? nPositions ?? maxSeqLen ?? seqLength
            )
        }
    }

    /// The sizing subset of `config.json`: the top level and the optional `text_config`.
    private struct RepoConfig: Decodable {
        let fields: SizingFields
        let textConfig: TextConfig?

        enum CodingKeys: String, CodingKey {
            case textConfig = "text_config"
        }

        init(from decoder: Decoder) throws {
            fields = try SizingFields(from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            textConfig = try container.decodeIfPresent(TextConfig.self, forKey: .textConfig)
        }

        /// The sizing source: the top level when resolved, else `textConfig`, else `nil`.
        /// Fields are never merged across the two levels.
        var sizingSource: ResolvedSizing? {
            fields.resolved ?? textConfig?.fields.resolved
        }

        /// The nested `text_config` object, decoded as ``SizingFields``.
        struct TextConfig: Decodable {
            let fields: SizingFields

            init(from decoder: Decoder) throws {
                fields = try SizingFields(from: decoder)
            }
        }
    }

    /// One entry of the repo tree listing. `lfs.size` is the real size of an LFS object.
    private struct TreeEntry: Decodable {
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable {
            let size: Int64?
        }
    }
}

/// Reads ``RepoMetadata`` for a ``ModelRef`` and caches the parsed result per
/// `(repo, revision)` on disk.
public struct RepoMetadataReader: Sendable {
    /// The injected fetch.
    private let source: MetadataSource

    /// The on-disk cache of parsed metadata.
    private let cache: RepoMetadataCache

    /// Creates a reader over a fetch source and a cache directory.
    ///
    /// - Parameters:
    ///   - source: The metadata fetch.
    ///   - cacheDir: The cache directory. It is created on demand.
    public init(source: MetadataSource, cacheDir: URL) {
        self.source = source
        self.cache = RepoMetadataCache(cacheDir: cacheDir)
    }

    /// Returns the parsed metadata for a model. Fetches and caches on a miss.
    ///
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the repo
    ///   lacks sizing inputs, or any error from the source or cache I/O.
    public func metadata(for ref: ModelRef) async throws -> RepoMetadata {
        if let cached = try cache.load(repo: ref.repo, revision: ref.revision) {
            return cached
        }
        let raw = try await source.fetchRawMetadata(repo: ref.repo, revision: ref.revision)
        let parsed = try RepoMetadata(raw: raw)
        try cache.save(parsed, repo: ref.repo, revision: ref.revision)
        return parsed
    }

    /// Returns the memory footprint estimate for a model.
    ///
    /// - Throws: As ``metadata(for:)``.
    public func footprint(for ref: ModelRef) async throws -> Footprint {
        try await metadata(for: ref).footprint
    }
}

/// The logger for cache decode failures.
private let repoMetadataCacheLogger = makeModuleLogger(category: "RepoMetadataCache")

/// A disposable on-disk cache of parsed ``RepoMetadata``, keyed by `(repo, revision)`.
/// Each key maps to its own JSON file.
struct RepoMetadataCache: Sendable {
    /// The directory under which metadata JSON files are written.
    let cacheDir: URL

    /// Loads the cached metadata for a `(repo, revision)`, if present.
    ///
    /// - Returns: The cached metadata, or `nil` when nothing is cached or the
    ///   cached entry fails to decode. A decode failure is logged.
    /// - Throws: If a cached file exists but cannot be read.
    func load(repo: String, revision: String?) throws -> RepoMetadata? {
        let url = fileURL(repo: repo, revision: revision)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(RepoMetadata.self, from: data)
        } catch {
            repoMetadataCacheLogger.error(
                "repo metadata cache entry failed to decode (stale schema or corruption); treating as a cache miss: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Saves metadata under its `(repo, revision)` key. Overwrites an existing entry.
    ///
    /// - Throws: If the directory cannot be created or the file cannot be written.
    func save(_ metadata: RepoMetadata, repo: String, revision: String?) throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = fileURL(repo: repo, revision: revision)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    /// The file URL for a `(repo, revision)` key. The key is hashed into a filesystem-safe name.
    func fileURL(repo: String, revision: String?) -> URL {
        let key = "\(repo)\u{0}\(revision ?? "")"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("repo-metadata-\(hex).json", isDirectory: false)
    }
}

/// The live ``MetadataSource`` that reads the two sizing artifacts from the
/// Hugging Face Hub HTTP API. A missing `config.json` (HTTP 404) yields a `nil` `configJSON`.
public struct HuggingFaceMetadataSource: MetadataSource {
    /// The Hub origin, e.g. `https://huggingface.co`.
    private let endpoint: URL

    /// The session used for the GET requests.
    private let session: URLSession

    /// The revision used when a `ModelRef` does not pin one.
    private static let defaultRevision = "main"

    /// Creates a live source. `endpoint` defaults to `https://huggingface.co`; `session` to `.shared`.
    public init(
        // The literal is a fixed, well-formed URL string, so a failed parse
        // here can only mean the literal itself was typo'd — a programmer
        // error, not a runtime condition to recover from.
        endpoint: URL = {
            guard let url = URL(string: "https://huggingface.co") else {
                preconditionFailure("https://huggingface.co is a fixed, well-formed URL literal")
            }
            return url
        }(),
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Fetches `config.json` and the tree listing for a repo at a revision (`nil` means `main`).
    ///
    /// - Throws: Any transport error other than a `config.json` 404.
    public func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        let rev = revision ?? Self.defaultRevision
        let configURL = endpoint.appendingPathComponent("\(repo)/resolve/\(rev)/config.json")
        let treeURL = endpoint
            .appendingPathComponent("api/models/\(repo)/tree/\(rev)")

        let configJSON = try await optionalData(from: configURL)
        let (treeJSON, _) = try await session.data(from: treeURL)
        return RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// Fetches bytes from a URL. Returns `nil` on HTTP 404.
    ///
    /// - Throws: Any transport error other than a 404.
    private func optionalData(from url: URL) async throws -> Data? {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        return data
    }
}
