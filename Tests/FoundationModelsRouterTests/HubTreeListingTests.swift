import Foundation
import Testing

@testable import FoundationModelsRouter

/// Proves that ``HubTreeListing`` writes each entry in the shape the Hub
/// lists it, so the sizing reader parses a built listing as it parses a
/// recorded one.
@Suite("HubTreeListing")
struct HubTreeListingTests {
    /// The `config.json` the reader needs beside a safetensors listing.
    private static let configJSON = Data(
        """
        {"num_hidden_layers": 1, "num_attention_heads": 1, "num_key_value_heads": 1,
         "head_dim": 1, "hidden_size": 1, "max_position_embeddings": 8192}
        """.utf8)

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
        #expect(try Self.weightBytes([.file("model.safetensors", size: 700)]) == 700)
    }

    @Test("an LFS file is sized by its LFS object, not its pointer")
    func lfsFileIsSizedByObject() throws {
        #expect(try Self.weightBytes([.lfsFile("model.safetensors", size: 9_000)]) == 9_000)
    }

    @Test("a directory entry adds no bytes")
    func directoryAddsNoBytes() throws {
        let entries: [HubTreeListing.Entry] = [.directory("docs"), .file("model.safetensors", size: 700)]

        #expect(try Self.weightBytes(entries) == 700)
    }

    @Test("shards are sized as the sum of their sizes")
    func shardsAreSummed() throws {
        let raw = RawRepoMetadata(configJSON: Self.configJSON, treeJSON: HubTreeListing.shards([300, 400]))

        #expect(try RepoMetadata(raw: raw, repo: "org/model").weightBytes == 700)
    }
}
