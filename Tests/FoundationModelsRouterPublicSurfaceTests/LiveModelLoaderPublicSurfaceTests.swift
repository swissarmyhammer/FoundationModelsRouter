import Foundation
import Testing

import FoundationModelsRouter

/// Holds the cache folder of `LiveModelLoader` to the access level that a
/// host outside this package needs (task ^1056ce6): a host, for example an
/// app that keeps each folder in Application Support, gives the Hugging Face
/// cache folder of its models to the public init.
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: an init that loses `public` or its `cacheDirectory`
/// parameter stops this file from compiling before a single test runs. The
/// body then shows that the init only keeps the folder: it downloads nothing
/// and writes nothing into the folder.
@Suite("Live loader cache folder over a plain import")
struct LiveModelLoaderPublicSurfaceTests {
    @Test("a host makes a live loader over its own cache folder, and the init writes nothing there")
    func hostGivesTheCacheFolder() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        _ = LiveModelLoader(reporting: { _ in }, cacheDirectory: folder)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }
}
