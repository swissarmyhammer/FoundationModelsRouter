import Foundation
import Testing

/// The Swift files of the library source tree, for a suite that reads the
/// library source as text: the upstream asks document check and the ACP
/// import scan.
enum LibrarySourceFiles {
    /// The path of the library source tree, relative to the repository root.
    static let librarySourcePath = "Sources/FoundationModelsRouter"

    /// The path extension of each library source file.
    private static let sourceFileExtension = "swift"

    /// Every Swift file under `Sources/FoundationModelsRouter`, at any depth.
    ///
    /// - Parameter repositoryRoot: The repository root, from
    ///   ``RepositoryRoot/url(from:)`` in the calling suite.
    /// - Returns: The source files.
    /// - Throws: An expectation failure when the tree cannot be enumerated
    ///   or holds no Swift file.
    static func urls(under repositoryRoot: URL) throws -> [URL] {
        let sourceRoot = repositoryRoot.appendingPathComponent(librarySourcePath, isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil),
            "the source tree at \(sourceRoot.path) cannot be enumerated"
        )
        let files = enumerator
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == sourceFileExtension }
        try #require(!files.isEmpty, "the source tree at \(sourceRoot.path) holds no Swift file")
        return files
    }
}
