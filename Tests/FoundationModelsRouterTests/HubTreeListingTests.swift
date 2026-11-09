import Foundation
import Testing

@testable import FoundationModelsRouter

/// Proves that ``HubTreeListing`` writes each entry in the shape the Hub
/// lists it, so the sizing reader parses a built listing as it parses a
/// recorded one.
@Suite("HubTreeListing")
struct HubTreeListingTests {
    /// The `max_position_embeddings` of ``configJSON``: 8K tokens, a common
    /// native window. The reader needs one to size a repo, and these tests
    /// read only weight bytes, so any plausible window does.
    private static let nativeContext = 8192

    /// The `config.json` the reader needs beside a safetensors listing.
    private static let configJSON = Data(
        """
        {"num_hidden_layers": 1, "num_attention_heads": 1, "num_key_value_heads": 1,
         "head_dim": 1, "hidden_size": 1, "max_position_embeddings": \(nativeContext)}
        """.utf8)

    /// The size of the plain weight file: small and arbitrary, and far from
    /// ``HubTreeListing/lfsPointerSize``, so it cannot be mistaken for a
    /// pointer size.
    private static let plainFileBytes: Int64 = 700

    /// The size of the LFS object: far from ``HubTreeListing/lfsPointerSize``,
    /// so a reader that sized the pointer instead of the object shows.
    private static let lfsObjectBytes: Int64 = 9_000

    /// The size of the first shard: unequal to ``secondShardBytes``, so a
    /// reader that counted one shard twice shows.
    private static let firstShardBytes: Int64 = 300

    /// The size of the second shard. With ``firstShardBytes`` it sums to
    /// ``plainFileBytes``.
    private static let secondShardBytes: Int64 = 400

    /// Sizes a listing as the reader sizes a repo.
    ///
    /// - Parameter entries: The entries of the listing.
    /// - Returns: The weight bytes the reader finds.
    /// - Throws: The error of the reader.
    private static func weightBytes(_ entries: [HubTreeListing.Entry]) throws -> Int64 {
        let raw = RawRepoMetadata(configJSON: configJSON, treeJSON: HubTreeListing.json(entries))
        return try RepoMetadata(raw: raw, repo: "org/model").weightBytes
    }

    @Test("a plain file is sized by its size")
    func plainFileIsSizedBySize() throws {
        #expect(try Self.weightBytes([.file("model.safetensors", size: Self.plainFileBytes)]) == Self.plainFileBytes)
    }

    @Test("an LFS file is sized by its LFS object, not its pointer")
    func lfsFileIsSizedByObject() throws {
        #expect(try Self.weightBytes([.lfsFile("model.safetensors", size: Self.lfsObjectBytes)]) == Self.lfsObjectBytes)
    }

    @Test("a directory entry adds no bytes")
    func directoryAddsNoBytes() throws {
        let entries: [HubTreeListing.Entry] = [
            .directory("docs"), .file("model.safetensors", size: Self.plainFileBytes),
        ]

        #expect(try Self.weightBytes(entries) == Self.plainFileBytes)
    }

    @Test("shards are sized as the sum of their sizes")
    func shardsAreSummed() throws {
        let raw = RawRepoMetadata(
            configJSON: Self.configJSON,
            treeJSON: HubTreeListing.shards([Self.firstShardBytes, Self.secondShardBytes]))

        #expect(
            try RepoMetadata(raw: raw, repo: "org/model").weightBytes
                == Self.firstShardBytes + Self.secondShardBytes)
    }
}
