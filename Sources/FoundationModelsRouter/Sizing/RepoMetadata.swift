import CryptoKit
import Foundation

/// The two small artifacts a repo's sizing needs, fetched verbatim from the Hub
/// without downloading any weights.
///
/// `configJSON` is the bytes of the repo's `config.json` at the revision, or
/// `nil` when the repo has none. `treeJSON` is the bytes of the repo tree
/// listing (`…/tree/{rev}`) used to sum `*.safetensors` file sizes. Both are
/// kept as raw bytes so the network layer stays a pure transport and all parsing
/// lives in ``RepoMetadata`` — which makes the parsing testable from canned
/// fixtures with no I/O.
public struct RawRepoMetadata: Sendable {
    /// The bytes of `config.json` at the revision, or `nil` when absent.
    public let configJSON: Data?

    /// The bytes of the repo tree listing JSON (`…/tree/{rev}`).
    public let treeJSON: Data

    /// Creates a raw metadata bundle.
    ///
    /// - Parameters:
    ///   - configJSON: The `config.json` bytes, or `nil` when the repo has none.
    ///   - treeJSON: The repo tree listing JSON bytes.
    public init(configJSON: Data?, treeJSON: Data) {
        self.configJSON = configJSON
        self.treeJSON = treeJSON
    }
}

/// The fetch behind ``RepoMetadataReader``, abstracted so the parsing, fit, and
/// cache logic stays pure and testable with canned fixtures.
///
/// The live implementation is ``HuggingFaceMetadataSource``; tests supply a stub
/// returning canned JSON so unit tests never touch the network.
public protocol MetadataSource: Sendable {
    /// Fetches the raw `config.json` and tree listing for a repo at a revision.
    ///
    /// - Parameters:
    ///   - repo: The Hugging Face repository id, e.g. `"org/repo"`.
    ///   - revision: The pinned revision, or `nil` for the default revision.
    /// - Returns: The raw bytes of both artifacts.
    /// - Throws: If the underlying transport fails.
    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata
}

/// A failure reading a repo's sizing metadata.
///
/// `metadataUnavailable` carries a human-readable reason and is surfaced — never
/// a crash — whenever a repo lacks the inputs sizing needs (no `config.json`, no
/// `*.safetensors`, or a config missing required architecture fields), so the
/// resolver can record the candidate as unavailable and skip it.
public enum RepoMetadataError: Error, Equatable {
    /// The repo cannot be sized; the associated value explains why.
    case metadataUnavailable(String)
}

/// The parsed sizing metadata for one repo at one revision: the resident weight
/// bytes and the attention architecture needed for the KV-cache math.
///
/// The type is pure value data — `Sendable`, `Equatable`, and `Codable` — so it
/// caches to disk and round-trips cleanly. It holds the raw config-shaped fields
/// (with the GQA and head-dim fallbacks left unapplied) and defers the fallback
/// arithmetic to ``Footprint``'s config-shaped initializer, keeping a single
/// source of truth for those rules.
public struct RepoMetadata: Sendable, Equatable, Codable {
    /// Resident weight bytes — `Σ size(*.safetensors)`, ≈ 1:1 from disk.
    public let weightBytes: Int64

    /// Transformer layer count (`num_hidden_layers`).
    public let numHiddenLayers: Int

    /// Query head count (`num_attention_heads`).
    public let numAttentionHeads: Int

    /// Key/value head count (`num_key_value_heads`); `nil` for multi-head
    /// attention, where the footprint falls back to `numAttentionHeads`.
    public let numKeyValueHeads: Int?

    /// Per-head dimension (`head_dim`); `nil` when the config omits it, where the
    /// footprint derives it from `hiddenSize / numAttentionHeads`.
    public let headDim: Int?

    /// Model hidden size (`hidden_size`); used to derive `headDim` when absent.
    public let hiddenSize: Int?

    /// Creates parsed metadata from already-resolved values.
    ///
    /// - Parameters:
    ///   - weightBytes: Resident weight bytes (`Σ *.safetensors`).
    ///   - numHiddenLayers: Transformer layer count.
    ///   - numAttentionHeads: Query head count.
    ///   - numKeyValueHeads: Key/value head count, or `nil` for MHA.
    ///   - headDim: Per-head dimension, or `nil` to derive from `hiddenSize`.
    ///   - hiddenSize: Hidden size, used only to derive `headDim` when absent.
    public init(
        weightBytes: Int64,
        numHiddenLayers: Int,
        numAttentionHeads: Int,
        numKeyValueHeads: Int?,
        headDim: Int?,
        hiddenSize: Int?
    ) {
        self.weightBytes = weightBytes
        self.numHiddenLayers = numHiddenLayers
        self.numAttentionHeads = numAttentionHeads
        self.numKeyValueHeads = numKeyValueHeads
        self.headDim = headDim
        self.hiddenSize = hiddenSize
    }

    /// Parses sizing metadata from raw fetched artifacts.
    ///
    /// Surfaces ``RepoMetadataError/metadataUnavailable(_:)`` — never crashes —
    /// when `config.json` is absent or unparseable, when it lacks the required
    /// `num_hidden_layers`/`num_attention_heads`, when it has neither `head_dim`
    /// nor `hidden_size` to size a head, or when the tree has no `*.safetensors`.
    ///
    /// - Parameter raw: The raw `config.json` and tree listing bytes.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when sizing inputs
    ///   are missing.
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
        self.init(
            weightBytes: weightBytes,
            numHiddenLayers: sizing.numHiddenLayers!,
            numAttentionHeads: sizing.numAttentionHeads!,
            numKeyValueHeads: sizing.numKeyValueHeads,
            headDim: sizing.headDim,
            hiddenSize: sizing.hiddenSize
        )
    }

    /// The memory footprint estimate for this repo, applying the GQA and head-dim
    /// fallbacks via ``Footprint``'s config-shaped initializer.
    public var footprint: Footprint {
        Footprint(
            weightBytes: weightBytes,
            numHiddenLayers: numHiddenLayers,
            numAttentionHeads: numAttentionHeads,
            numKeyValueHeads: numKeyValueHeads,
            headDim: headDim,
            hiddenSize: hiddenSize
        )
    }

    /// Sums the LFS-aware sizes of every `*.safetensors` file in a tree listing.
    ///
    /// Quantized weights load ≈ 1:1 from disk, so the sum is the resident weight
    /// bytes directly. For Git-LFS-tracked files the listing's top-level `size`
    /// is the pointer size, so the real `lfs.size` is preferred when present.
    ///
    /// - Parameter treeJSON: The repo tree listing JSON bytes.
    /// - Returns: The summed resident weight bytes.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the tree has
    ///   no `*.safetensors` files (or none with a positive size).
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

    /// The five architecture fields the KV math needs, resolved from one
    /// coherent source — never mixed across the top level and `text_config`.
    private typealias SizingFields = (
        numHiddenLayers: Int?, numAttentionHeads: Int?, numKeyValueHeads: Int?, headDim: Int?, hiddenSize: Int?
    )

    /// The architecture subset of `config.json` the KV math needs. Every field
    /// is optional so a sparse or unexpected config decodes without throwing;
    /// ``init(raw:)`` enforces which fields must be present.
    ///
    /// VLM repos (e.g. the Qwen-VL family) nest the language-model sizing
    /// fields under `text_config` instead of the top level, alongside a
    /// sibling `vision_config` that uses distinct field names. `textConfig` is
    /// decoded so ``sizingSource`` can fall back to it as a whole.
    private struct RepoConfig: Decodable {
        let numHiddenLayers: Int?
        let numAttentionHeads: Int?
        let numKeyValueHeads: Int?
        let headDim: Int?
        let hiddenSize: Int?
        let textConfig: TextConfig?

        enum CodingKeys: String, CodingKey {
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case hiddenSize = "hidden_size"
            case textConfig = "text_config"
        }

        /// The coherent sizing source for this config: the top level when it
        /// has both required fields (`numHiddenLayers`, `numAttentionHeads`);
        /// otherwise `textConfig` when it has both; otherwise `nil`.
        ///
        /// This mirrors HF transformers' own `get_text_config()` semantics —
        /// a composite config's language-model fields are read as a unit from
        /// one object, never per-field merged across levels, which could
        /// otherwise stitch together fields from different stacks (e.g. a
        /// top-level projector `hidden_size` with `text_config`'s head
        /// counts) and silently size the KV cache wrong.
        var sizingSource: SizingFields? {
            if numHiddenLayers != nil, numAttentionHeads != nil {
                return (numHiddenLayers, numAttentionHeads, numKeyValueHeads, headDim, hiddenSize)
            }
            if let textConfig, textConfig.numHiddenLayers != nil, textConfig.numAttentionHeads != nil {
                return (
                    textConfig.numHiddenLayers,
                    textConfig.numAttentionHeads,
                    textConfig.numKeyValueHeads,
                    textConfig.headDim,
                    textConfig.hiddenSize
                )
            }
            return nil
        }

        /// The nested VLM language-model config (`text_config`), decoding the
        /// same five sizing fields as `RepoConfig`'s top level.
        struct TextConfig: Decodable {
            let numHiddenLayers: Int?
            let numAttentionHeads: Int?
            let numKeyValueHeads: Int?
            let headDim: Int?
            let hiddenSize: Int?

            enum CodingKeys: String, CodingKey {
                case numHiddenLayers = "num_hidden_layers"
                case numAttentionHeads = "num_attention_heads"
                case numKeyValueHeads = "num_key_value_heads"
                case headDim = "head_dim"
                case hiddenSize = "hidden_size"
            }
        }
    }

    /// One entry of the repo tree listing. `size` is the plain file size (the LFS
    /// pointer size for LFS files); `lfs.size` is the real size of an LFS object.
    private struct TreeEntry: Decodable {
        let path: String
        let size: Int64?
        let lfs: LFS?

        struct LFS: Decodable {
            let size: Int64?
        }
    }
}

/// Reads ``RepoMetadata`` for a ``ModelRef``, caching the parsed result per
/// `(repo, revision)` on disk so repeated reads skip the network.
///
/// The fetch is injected as a ``MetadataSource`` so the reader is testable with
/// canned fixtures. The cache is disposable — deleting it only forces a re-fetch,
/// never data loss.
public struct RepoMetadataReader: Sendable {
    /// The injected fetch.
    private let source: MetadataSource

    /// The on-disk cache of parsed metadata keyed by `(repo, revision)`.
    private let cache: RepoMetadataCache

    /// Creates a reader over a fetch source and a cache directory.
    ///
    /// - Parameters:
    ///   - source: The metadata fetch; ``HuggingFaceMetadataSource`` for live
    ///     reads or a stub for tests.
    ///   - cacheDir: The disposable directory under which parsed metadata is
    ///     cached. Created on demand; it need not exist yet.
    public init(source: MetadataSource, cacheDir: URL) {
        self.source = source
        self.cache = RepoMetadataCache(cacheDir: cacheDir)
    }

    /// Returns the parsed metadata for a model, fetching and caching on a miss.
    ///
    /// A cached entry for the `(repo, revision)` is returned without invoking the
    /// source; otherwise the source is fetched once, parsed, and cached.
    ///
    /// - Parameter ref: The model reference to size.
    /// - Returns: The parsed sizing metadata.
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
    /// - Parameter ref: The model reference to size.
    /// - Returns: The footprint, with the GQA and head-dim fallbacks applied.
    /// - Throws: As ``metadata(for:)``.
    public func footprint(for ref: ModelRef) async throws -> Footprint {
        try await metadata(for: ref).footprint
    }
}

/// A disposable on-disk cache of parsed ``RepoMetadata``, keyed by
/// `(repo, revision)`.
///
/// Each key maps to its own JSON file under a configured directory, so distinct
/// repos and revisions never collide. The cache is disposable — deleting it only
/// forces a re-fetch — and mirrors ``HostProfileCache``'s shape.
struct RepoMetadataCache: Sendable {
    /// The directory under which metadata JSON files are written.
    let cacheDir: URL

    /// Loads the cached metadata for a `(repo, revision)`, if present.
    ///
    /// - Parameters:
    ///   - repo: The repository id.
    ///   - revision: The pinned revision, or `nil` for the default.
    /// - Returns: The cached metadata, or `nil` when nothing is cached.
    /// - Throws: If a cached file exists but cannot be read or decoded.
    func load(repo: String, revision: String?) throws -> RepoMetadata? {
        let url = fileURL(repo: repo, revision: revision)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RepoMetadata.self, from: data)
    }

    /// Saves metadata under its `(repo, revision)` key, creating the cache
    /// directory if needed and overwriting any existing entry for the key.
    ///
    /// - Parameters:
    ///   - metadata: The parsed metadata to persist.
    ///   - repo: The repository id.
    ///   - revision: The pinned revision, or `nil` for the default.
    /// - Throws: If the directory cannot be created or the file cannot be written.
    func save(_ metadata: RepoMetadata, repo: String, revision: String?) throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let url = fileURL(repo: repo, revision: revision)
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    /// The file URL for a `(repo, revision)` key.
    ///
    /// The key components are hashed into a collision-resistant filename so
    /// arbitrary repo strings stay filesystem-safe and distinct keys map to
    /// distinct files.
    private func fileURL(repo: String, revision: String?) -> URL {
        let key = "\(repo)\u{0}\(revision ?? "")"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent("repo-metadata-\(hex).json", isDirectory: false)
    }
}

/// The live ``MetadataSource`` that reads the two sizing artifacts from the
/// Hugging Face Hub HTTP API without downloading weights.
///
/// `config.json` is read from the resolve endpoint and the weight sizes from the
/// tree-listing API, both pinned to the requested revision (defaulting to
/// `main`). A missing `config.json` (HTTP 404) yields a `nil` `configJSON` so the
/// reader can surface ``RepoMetadataError/metadataUnavailable(_:)`` rather than
/// failing the fetch.
public struct HuggingFaceMetadataSource: MetadataSource {
    /// The Hub origin, e.g. `https://huggingface.co`.
    private let endpoint: URL

    /// The session used for the two small GET requests.
    private let session: URLSession

    /// The revision used when a `ModelRef` does not pin one.
    private static let defaultRevision = "main"

    /// Creates a live source.
    ///
    /// - Parameters:
    ///   - endpoint: The Hub origin. Defaults to `https://huggingface.co`.
    ///   - session: The URL session to use. Defaults to `.shared`.
    public init(
        endpoint: URL = URL(string: "https://huggingface.co")!,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Fetches `config.json` and the tree listing for a repo at a revision.
    ///
    /// - Parameters:
    ///   - repo: The repository id, e.g. `"org/repo"`.
    ///   - revision: The pinned revision, or `nil` for `main`.
    /// - Returns: The raw bytes, with `configJSON` `nil` when the repo has none.
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

    /// Fetches bytes from a URL, returning `nil` for an HTTP 404 so a missing
    /// `config.json` is reported as absent rather than thrown.
    ///
    /// - Parameter url: The URL to GET.
    /// - Returns: The response bytes, or `nil` on HTTP 404.
    /// - Throws: Any transport error other than a 404.
    private func optionalData(from url: URL) async throws -> Data? {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return nil
        }
        return data
    }
}
