import Foundation
import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// Proves that the public init of a ``LiveModelLoader`` gives its offline
/// mode to the Extras `HubModelLoader`. In the offline mode, the loader sends
/// no request to the Hub, and a model that the cache does not hold throws
/// `ModelDownloadError.notCachedOffline`.
@Suite("Offline mode of the live loader")
struct LiveModelLoaderOfflineTests {
    /// A model that the empty cache of the test does not hold.
    private static let ref: ModelRef = "router-tests/offline-model"

    /// The revision that the loader reads when the model names no revision.
    private static let mainRef = "main"

    @Test("an offline live loader throws notCachedOffline for a model that its cache does not hold")
    func offlineLoaderThrowsNotCachedOffline() async throws {
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = LiveModelLoader(cacheDirectory: cache, offline: true)

        await #expect(throws: ModelDownloadError.notCachedOffline(repository: Self.ref.repo, revision: Self.mainRef)) {
            try await loader.footprintBytes(of: ModelPoolKey(ref: Self.ref, role: .llm))
        }
    }
}
