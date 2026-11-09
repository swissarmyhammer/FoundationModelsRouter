import Foundation

@testable import FoundationModelsRouter

/// A ``MetadataSource`` that answers each read from fixed bytes: the
/// metadata of each repo, and the bytes of each file by its repo and its
/// path. A GGUF sizing test gives it a tree listing and the GGUF header of
/// each model. It records each range it read.
actor FileServingMetadataSource: MetadataSource {
    /// A read of a file the source does not hold.
    struct MissingFile: Error, Equatable {
        /// The repo and the path of the file.
        let location: String
    }

    /// The metadata of each repo.
    private let rawByRepo: [String: RawRepoMetadata]

    /// The metadata of a repo with no entry in ``rawByRepo``.
    private let defaultRaw: RawRepoMetadata

    /// The bytes of each file, by `repo/path`.
    private let files: [String: Data]

    /// Each range read, in the order of the reads.
    private(set) var readRanges: [Range<Int>] = []

    /// Makes a source.
    ///
    /// - Parameters:
    ///   - rawByRepo: The metadata of each repo.
    ///   - defaultRaw: The metadata of each other repo.
    ///   - files: The bytes of each file, by `repo/path`.
    init(rawByRepo: [String: RawRepoMetadata], defaultRaw: RawRepoMetadata, files: [String: Data]) {
        self.rawByRepo = rawByRepo
        self.defaultRaw = defaultRaw
        self.files = files
    }

    func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
        rawByRepo[repo] ?? defaultRaw
    }

    func fetchFileBytes(repo: String, revision: String?, path: String, range: Range<Int>) async throws -> Data {
        readRanges.append(range)
        let location = "\(repo)/\(path)"
        guard let bytes = files[location] else { throw MissingFile(location: location) }
        return bytes.subdata(in: range.clamped(to: 0..<bytes.count))
    }

    /// One file of a tree listing, as the Hub lists an LFS file.
    ///
    /// - Parameters:
    ///   - path: The path of the file.
    ///   - size: The size of the LFS object.
    /// - Returns: The JSON object of the file.
    static func treeFile(_ path: String, size: Int64) -> String {
        #"{"type": "file", "path": "\#(path)", "size": 135, "lfs": {"size": \#(size)}}"#
    }

    /// A tree listing of some files.
    ///
    /// - Parameter files: The JSON object of each file.
    /// - Returns: The bytes of the listing.
    static func tree(_ files: [String]) -> Data {
        Data("[\(files.joined(separator: ","))]".utf8)
    }
}
