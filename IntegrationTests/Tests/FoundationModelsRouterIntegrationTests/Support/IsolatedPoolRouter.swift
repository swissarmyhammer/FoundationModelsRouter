import Foundation
import FoundationModels
import FoundationModelsRouter
import Testing

/// One router over a live loader and a pool of its own, and the directory it
/// caches under.
///
/// The pool is never `ModelPool.shared`, so no other suite can hold a model in
/// it, and a test reads the eviction of each model of a profile from it.
struct IsolatedPoolRouter {
    /// The directory the router caches its sizing metadata under.
    let root: URL

    /// The pool the router resolves into.
    let pool: ModelPool

    /// The router.
    let router: Router

    /// Makes a router over a live loader and a new pool.
    ///
    /// - Parameters:
    ///   - label: The prefix of the name of the cache directory, usually the
    ///     name of the suite.
    ///   - samplingMode: The decoding of each generation of the router.
    init(label: String, samplingMode: GenerationOptions.SamplingMode) {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        pool = ModelPool()
        router = Router(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            loader: LiveModelLoader(),
            samplingMode: samplingMode,
            pool: pool
        )
    }

    /// Resolves `profile`, gives the resolved profile to `body`, then drops the
    /// profile and expects the pool to drain until it has no resident model.
    ///
    /// `body` must not keep the resolved profile, or a session of it, past its
    /// return, so the drop releases the last reference to each model, and the
    /// pool evicts it.
    ///
    /// - Parameters:
    ///   - profile: The authored profile.
    ///   - body: The work on the resolved profile.
    /// - Returns: What `body` returned.
    /// - Throws: Whatever the resolve or `body` throws.
    func withResolved<Result>(
        _ profile: ProfileDefinition, _ body: (LanguageModelProfile) async throws -> Result
    ) async throws -> Result {
        var resolved: LanguageModelProfile? = try await router.resolve(
            profile: profile, reporting: ResolutionProgress())
        let result = try await body(try #require(resolved))
        resolved = nil
        #expect(await pool.awaitNoResidentModel())
        return result
    }

    /// Removes the cache directory of the router.
    func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }
}
