import Foundation
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Proves that the public init of a ``LiveModelLoader`` gives its offline
/// mode to the Extras `HubModelLoader` and to its `LlamaCppModelLoader`. In
/// the offline mode, the loader sends no request to the Hub, and a model that
/// the cache does not hold throws `ModelDownloadError.notCachedOffline`.
@Suite("Offline mode of the live loader")
struct LiveModelLoaderOfflineTests {
    /// A model that the empty cache of the test does not hold.
    private static let ref: ModelRef = "router-tests/offline-model"

    /// A GGUF model whose drafter the cache of the test does not hold.
    private static let ggufRef = ModelRef(
        repo: "router-tests/offline-gguf-model", drafter: "router-tests/offline-gguf-drafter")

    /// The commit of the fake snapshot of ``ggufRef``.
    private static let ggufCommit = "0123456789abcdef0123456789abcdef01234567"

    /// The one GGUF file of the fake snapshot of ``ggufRef``, and its bytes.
    private static let ggufFiles = ["model.gguf": 1]

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

    @Test("an offline live loader throws notCachedOffline for a GGUF model whose drafter its cache does not hold")
    func offlineLoaderThrowsNotCachedOfflineForTheGGUFDrafter() async throws {
        let cache = try FakeHubCache.make(ref: Self.ggufRef, commit: Self.ggufCommit, files: Self.ggufFiles)
        defer { try? FileManager.default.removeItem(at: cache) }
        let loader = LiveModelLoader(cacheDirectory: cache, offline: true)
        let drafter = try #require(Self.ggufRef.drafter)

        await #expect(throws: ModelDownloadError.notCachedOffline(repository: drafter.repo, revision: Self.mainRef)) {
            try await loader.load(ModelPoolKey(ref: Self.ggufRef, role: .llm))
        }
    }

    @Test("a live loader made with offline false lets its GGUF loader download")
    func onlineLoaderGivesFalseToTheGGUFLoader() throws {
        let loader = LiveModelLoader(offline: false)

        #expect(try !loader.requireGGUFHubSource().offline)
    }
}
