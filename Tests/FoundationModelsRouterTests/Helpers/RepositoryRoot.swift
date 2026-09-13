import Foundation

/// The repository root, for a suite that reads a file the repository
/// carries: the README, the CI workflow, or `UPSTREAM_ASKS.md`.
///
/// The root is resolved from the calling suite's own source path. Every
/// suite in this target sits directly inside
/// `Tests/FoundationModelsRouterTests/`, two directories below the root, so
/// the resolution removes three path components: the file name and the two
/// directories. Keep each calling suite at that depth.
enum RepositoryRoot {
    /// How many path components stand between a suite file and the root:
    /// the file name, `FoundationModelsRouterTests/`, and `Tests/`.
    private static let componentsBelowRoot = 3

    /// The repository root that holds `suiteFile`.
    ///
    /// - Parameter suiteFile: The calling suite's own source path. The
    ///   default is `#filePath`, which expands at the call site.
    /// - Returns: The root directory.
    static func url(from suiteFile: String = #filePath) -> URL {
        var root = URL(fileURLWithPath: suiteFile)
        for _ in 0..<componentsBelowRoot {
            root.deleteLastPathComponent()
        }
        return root
    }
}
