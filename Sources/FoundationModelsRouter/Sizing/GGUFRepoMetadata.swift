import Foundation
import FoundationModelsExtras
import FoundationModelsLlamaCpp

extension RepoMetadata {
    /// The separator of the segments of a tree path.
    private static let ggufPathSeparator = "/"

    /// Creates the metadata of a GGUF model from the header of its first
    /// shard and the bytes of its files.
    ///
    /// The KV cache and the recurrent state come from the header
    /// (``GGUFCacheSizing``), and so does the native context: the training
    /// context of the model. So does the decision type of a decision model
    /// (``ggufDecisionType``). The architecture fields that an MLX model reads
    /// from `config.json` are filled from the header for the record; the
    /// footprint of a GGUF model does not read them.
    ///
    /// - Parameters:
    ///   - modelHeader: The parsed GGUF header of the model, or of the first
    ///     shard of its split set.
    ///   - weightBytes: The bytes of the shards of the model and of its projector.
    ///   - name: The name the errors give: a reference or a file path.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   header has no positive training context (`<arch>.context_length`).
    init(ggufHeader modelHeader: GGUFModelHeader, weightBytes: Int64, name: String) throws {
        let header = modelHeader.header
        guard let context = header.trainingContextSize, context > 0 else {
            throw RepoMetadataError.metadataUnavailable(
                "the GGUF header of \(name) has no positive \(header.architecture).context_length")
        }
        self.init(
            weightBytes: weightBytes,
            numHiddenLayers: header.blockCount,
            numAttentionHeads: header.headCount,
            numKeyValueHeads: nil,
            headDim: header.keyLength,
            hiddenSize: header.embeddingLength,
            numFullAttentionLayers: header.fullAttentionBlockCount,
            nativeMaxContext: context,
            gguf: GGUFCacheSizing(header: header),
            ggufDecisionType: modelHeader.decisionType
        )
    }

    /// Whether llama.cpp answers decision questions for the decision type of
    /// the model (``ggufDecisionType``): the native decision path.
    ///
    /// FoundationModelsLlamaCpp alone tells which types it supports, thus the
    /// router keeps no list of types.
    var hasNativeDecisionType: Bool {
        ggufDecisionType.flatMap(LlamaDecisionType.init(rawValue:))?.isSupportedByDecide ?? false
    }

    /// The bytes a drafter adds beside its weights at the context of its
    /// target: the context of a GGUF drafter (its KV cache and its recurrent
    /// state), which llama.cpp makes at the context of the target. An MLX
    /// drafter adds none: its cache is not sized.
    ///
    /// - Parameter context: The context of the target, in tokens.
    /// - Returns: The bytes, or 0 for a drafter that is not GGUF.
    func draftContextBytes(context: Int) -> Int64 {
        gguf?.bytes(context: context) ?? 0
    }

    /// The files of the GGUF model that a reference names in a tree listing,
    /// chosen as the Extras GGUF loader chooses them.
    ///
    /// The files under the path decide the format, as the Extras
    /// `HubModelLoader` decides it. A path whose files are not GGUF is an
    /// error, because only a GGUF model loads from a path.
    ///
    /// - Parameters:
    ///   - entries: Every file of the repository.
    ///   - path: The path of the reference inside the repository, or `nil`
    ///     for its root.
    ///   - name: The name the errors give.
    /// - Returns: The files of the model, or `nil` when the root of the
    ///   repository is not GGUF.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the path
    ///   is not GGUF, or when it holds no model, more than one model, or a
    ///   split set with a missing shard.
    static func ggufFileSet(in entries: [TreeEntry], under path: String?, name: String) throws -> GGUFFileSet? {
        let paths = entries.filter(\.isFile).map(\.path)
        let scoped = path.map { path in
            paths.filter { $0 == path || $0.hasPrefix(path + ggufPathSeparator) }
        } ?? paths
        guard HubModelFormat.detect(paths: scoped) == .gguf else {
            guard let path else { return nil }
            throw RepoMetadataError.metadataUnavailable(
                "\(name) names the path \(path) inside its repository, and the files there are not GGUF; "
                    + "only a GGUF model loads from a path")
        }
        do {
            return try GGUFFileSet.select(from: paths, under: path)
        } catch {
            throw RepoMetadataError.metadataUnavailable("\(name): \(error.localizedDescription)")
        }
    }

    /// The bytes of the files of a GGUF model in a tree listing: its shards
    /// and its projector.
    ///
    /// - Parameters:
    ///   - files: The files of the model.
    ///   - entries: Every file of the repository.
    /// - Returns: The sum of their sizes.
    static func ggufWeightBytes(of files: GGUFFileSet, in entries: [TreeEntry]) -> Int64 {
        let wanted = Set(files.files)
        return entries.filter { $0.isFile && wanted.contains($0.path) }.reduce(Int64(0)) { $0 + $1.byteCount }
    }

    /// Creates the metadata of a GGUF model on the disk: a `.gguf` file, or a
    /// folder of GGUF files. No Hub call is made.
    ///
    /// The Extras `GGUFSource` chooses the files, as the GGUF loader does:
    /// a file and the projector beside it, or the one model of a folder. The
    /// header is read from the start of the model file.
    ///
    /// - Parameter location: The absolute path of the file or the folder.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the files
    ///   cannot be chosen or read, or as ``init(ggufHeader:weightBytes:name:)``.
    init(localGGUF location: URL) async throws {
        let files: GGUFModelFiles
        let weightBytes: Int64
        do {
            files = try GGUFSource().cachedFiles(of: ModelRef(repo: location.path))
            weightBytes = try files.byteCount()
        } catch {
            throw RepoMetadataError.metadataUnavailable(
                "the local GGUF model \(location.path) cannot be sized: \(error.localizedDescription)")
        }
        let header = try await GGUFHeaderPrefix.read(name: files.model.path) { range in
            try Self.localBytes(of: files.model, range: range)
        }
        try self.init(ggufHeader: header, weightBytes: weightBytes, name: location.path)
    }

    /// Reads a range of the bytes of a file on the disk.
    ///
    /// - Parameters:
    ///   - file: The file.
    ///   - range: The byte offsets to read.
    /// - Returns: The bytes, fewer than asked at the end of the file.
    /// - Throws: The error of the read.
    private static func localBytes(of file: URL, range: Range<Int>) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        return try handle.read(upToCount: range.count) ?? Data()
    }
}

/// The parsed GGUF header of a model, and the decision type of its metadata,
/// which `GGUFHeader` does not keep.
struct GGUFModelHeader: Sendable {
    /// The key after the prefix of the architecture of the decision type of
    /// a decision model: `<arch>.decision.type`.
    private static let decisionTypeKey = "decision.type"

    /// The parsed header.
    let header: GGUFHeader

    /// The `STRING` value of `<arch>.decision.type`, or `nil` when the
    /// metadata has no such `STRING` value.
    let decisionType: String?

    /// Parses the header of a prefix of a GGUF file.
    ///
    /// - Parameter prefix: The first bytes of a GGUF file.
    /// - Throws: The error of `GGUFHeader.parse(prefix:)`, unchanged, for
    ///   example `GGUFHeaderError.needsMoreBytes(atLeast:)` when the prefix
    ///   ends before the metadata section ends.
    init(prefix: Data) throws {
        header = try GGUFHeader.parse(prefix: prefix)
        decisionType = GGUFMetadataScan.stringValue(
            of: "\(header.architecture).\(Self.decisionTypeKey)", in: prefix)
    }
}

/// Reads a GGUF header from the start of a file, a range at a time, so a
/// model on the Hub is sized with no download of its weights.
///
/// The first read is one megabyte. When the metadata section runs past the
/// bytes read, the next read fetches only the bytes past them. The array that
/// runs past the prefix sizes that read (``GGUFMetadataScan``): the tokenizer
/// arrays of a real model run to many megabytes, so the token array predicts
/// the arrays after it, and a model of 11 MB of metadata takes two reads.
/// When no array predicts the end, the read grows the prefix to twice its
/// bytes, because the parse of a later value can need more again.
enum GGUFHeaderPrefix {
    /// The bytes of the first read.
    static let initialByteCount = 1 << 20

    /// The factor by which a read that no array sizes grows the prefix.
    private static let growthFactor = 2

    /// Reads and parses the GGUF header of a file.
    ///
    /// - Parameters:
    ///   - name: The name of the file, for the errors.
    ///   - fetch: Reads a range of the bytes of the file. It gives fewer bytes
    ///     than asked at the end of the file.
    /// - Returns: The parsed header, with the decision type of its metadata.
    /// - Throws: ``RepoMetadataError/metadataUnavailable(_:)`` when the
    ///   header does not parse, or when the file ends before its metadata
    ///   section ends; or the error of `fetch`.
    static func read(name: String, fetch: (Range<Int>) async throws -> Data) async throws -> GGUFModelHeader {
        var prefix = try await fetch(0..<initialByteCount)
        while true {
            do {
                return try GGUFModelHeader(prefix: prefix)
            } catch GGUFHeaderError.needsMoreBytes(let atLeast) {
                let wanted = max(atLeast, nextReadEnd(after: prefix))
                let more = try await fetch(prefix.count..<wanted)
                guard !more.isEmpty else {
                    throw RepoMetadataError.metadataUnavailable(
                        "the file \(name) ends at byte \(prefix.count), before the end of its GGUF metadata")
                }
                prefix.append(more)
            } catch {
                throw RepoMetadataError.metadataUnavailable("the GGUF header of \(name) does not parse: \(error)")
            }
        }
    }

    /// The offset at which the read after a prefix should end: the end that
    /// the array past the prefix predicts, or twice the prefix when no array
    /// predicts one.
    ///
    /// - Parameter prefix: The bytes read so far, from the start of the file.
    /// - Returns: The offset, from the start of the file.
    private static func nextReadEnd(after prefix: Data) -> Int {
        GGUFMetadataScan(prefix: prefix)?.predictedEnd() ?? growthFactor * prefix.count
    }
}
