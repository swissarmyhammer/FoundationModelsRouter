import Foundation

/// The two temp directories that one test owns: the cache directory of its
/// routers and the durable recordings root. The test removes both with
/// ``remove()``, usually in a `defer`.
///
/// Every suite that resolves a profile over a cache and a recordings root
/// uses this one type, so the creation and the cleanup live in one place.
struct TestDirectories {
    /// The directory the routers cache into.
    let cacheDir: URL

    /// The directory the recorder writes the transcripts into.
    let recordingsDir: URL

    /// Makes a fresh, empty pair of temp directories.
    ///
    /// - Parameter prefix: The name of the suite. Each directory name starts
    ///   with it, then `-cache` or `-recordings`, then a UUID.
    init(prefix: String) {
        cacheDir = RouterTestFixtures.makeTempDir(prefix: "\(prefix)-cache")
        recordingsDir = RouterTestFixtures.makeTempDir(prefix: "\(prefix)-recordings")
    }

    /// Removes both directories and all that they hold.
    func remove() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.removeItem(at: recordingsDir)
    }
}
