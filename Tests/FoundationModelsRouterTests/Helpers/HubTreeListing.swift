import Foundation

/// Builds the JSON of a Hub tree listing, the reply of
/// `api/models/<repo>/tree`, for a test that serves repo metadata. Every
/// test builds its listing here, so the listing has one shape.
enum HubTreeListing {
    /// The size the Hub lists for the pointer file of an LFS object.
    static let lfsPointerSize: Int64 = 135

    /// One entry of a tree listing.
    enum Entry {
        /// A file that the Hub stores in git, listed by its size.
        case file(String, size: Int64)

        /// A file that the Hub stores in LFS: its listed size is the size
        /// of the pointer, and the size of the object is under `lfs`.
        case lfsFile(String, size: Int64, pointerSize: Int64 = HubTreeListing.lfsPointerSize)

        /// A directory, which the Hub lists with a size of zero.
        case directory(String)

        /// The JSON object of the entry.
        var json: String {
            switch self {
            case .file(let path, let size):
                #"{"type": "file", "path": "\#(path)", "size": \#(size)}"#
            case .lfsFile(let path, let size, let pointerSize):
                #"{"type": "file", "path": "\#(path)", "size": \#(pointerSize), "lfs": {"size": \#(size)}}"#
            case .directory(let path):
                #"{"type": "directory", "path": "\#(path)", "size": 0}"#
            }
        }
    }

    /// A tree listing of some entries.
    ///
    /// - Parameter entries: The entries of the listing, in order.
    /// - Returns: The bytes of the listing.
    static func json(_ entries: [Entry]) -> Data {
        Data("[\(entries.map(\.json).joined(separator: ","))]".utf8)
    }

    /// A tree listing of one model: one safetensors shard of each size,
    /// named `model-<index>.safetensors`.
    ///
    /// - Parameter sizes: The size of each shard.
    /// - Returns: The bytes of the listing.
    static func shards(_ sizes: [Int64]) -> Data {
        json(sizes.enumerated().map { .file("model-\($0.offset).safetensors", size: $0.element) })
    }
}
