import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests the runtime behavior of the code symbols the README section
/// "Residency is process-wide" names. Each symbol is referenced at compile
/// time, so a rename breaks the build before it breaks a reader. Each test
/// also asserts on a real value, so the suite can fail at run time.
@Suite("README symbols")
struct ReadmeSymbolsTests {
    /// A fresh cache directory for one router, under this suite's own prefix.
    private static func makeTempDir() -> URL {
        RouterTestFixtures.makeTempDir(prefix: "ReadmeSymbolsTests")
    }

    @Test("`Router(pool:)` resolves into the given pool in place of `ModelPool.shared`")
    func routerPoolTakesAnIsolatedPool() {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let router = Router(cacheDir: dir, pool: pool)
        #expect(router.pool === pool)
        #expect(router.pool !== ModelPool.shared)
    }

    @Test("`ModelPool.residentModelCount` is zero on a fresh pool")
    func freshPoolHoldsNoModel() {
        #expect(ModelPool().residentModelCount == 0)
    }

    @Test("`Router(samplingMode:)` keeps the decoding strategy on the router")
    func routerKeepsItsSamplingMode() async {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(cacheDir: dir, samplingMode: .greedy, pool: ModelPool())
        #expect(await router.samplingMode == .greedy)
    }
}
