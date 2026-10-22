import Foundation
import FoundationModelsExtras
import Testing

import FoundationModelsRouter

/// Holds ``Router/cacheDirectory`` to the access level that a host outside
/// this package needs: a host with its own home reads the folder of the
/// sizing metadata of its router, for example to prove that the folder is in
/// that home.
///
/// The import is plain, with no `@testable`, so a property that loses
/// `public` stops this file from compiling before a single test runs.
@Suite("Router.cacheDirectory over a plain import")
struct RouterCacheDirectoryPublicSurfaceTests {
    @Test("a router shows the metadata cache folder that the host gave")
    func givenFolderIsTheCacheDirectory() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let router = Router(cacheDir: folder, pool: ModelPool())

        #expect(router.cacheDirectory == folder)
    }

    @Test("a router with no cache folder shows the folder of the router module under the user caches folder")
    func defaultFolderIsUnderTheUserCaches() throws {
        let caches = try #require(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)

        let router = Router(pool: ModelPool())

        #expect(router.cacheDirectory == caches.appendingPathComponent("FoundationModelsRouter", isDirectory: true))
    }
}
