import Foundation
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

/// Pins that there is one ``ModelPool`` type. `FoundationModelsRouter` names
/// the Extras class through a public typealias, so a file that imports both
/// modules writes `ModelPool` with no ambiguity, and a router takes the pool
/// that the registry and the multitool take.
///
/// This file imports each module with a plain `import`, as an application
/// does. The file compiles only when the name is not ambiguous.
@Suite("One ModelPool type")
struct ModelPoolNameTests {
    @Test("the router name and the Extras name of ModelPool are one type")
    func routerAndExtrasNameOneType() {
        #expect(FoundationModelsRouter.ModelPool.self == FoundationModelsExtras.ModelPool.self)
    }

    @Test("a file that imports both modules makes a router over a ModelPool")
    func fileThatImportsBothModulesMakesARouter() {
        let dir = RouterTestFixtures.makeTempDir(prefix: "ModelPoolNameTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = ModelPool()
        let router = Router(cacheDir: dir, pool: pool)
        #expect(pool.residentModelCount == 0)
        #expect(pool !== ModelPool.shared)
        withExtendedLifetime(router) {}
    }
}
