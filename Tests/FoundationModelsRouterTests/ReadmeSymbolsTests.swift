import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Pins the code symbols the README section "Residency is process-wide"
/// names. Each symbol is referenced at compile time, so a rename breaks the
/// build before it breaks a reader. Each test also asserts on a real value,
/// so the suite can fail at run time.
@Suite("README symbols")
struct ReadmeSymbolsTests {
    /// The heading line of the README section this suite pins.
    private static let sectionHeading = "## Residency is process-wide"

    /// The path of the README, relative to the repository root.
    private static let readmePath = "README.md"

    /// The symbols the section names in backticks. A test below references
    /// each one at compile time.
    private static let pinnedSymbols = [
        "ModelPool.shared", "ModelPool.residentModelCount", "Router(pool:)", "Router(samplingMode:)",
    ]

    /// A fresh cache directory for one router, under this suite's own prefix.
    private static func makeTempDir() -> URL {
        RouterTestFixtures.makeTempDir(prefix: "ReadmeSymbolsTests")
    }

    /// The lines of the README section, from below its heading to the next
    /// heading of the same level.
    ///
    /// - Returns: The section lines, or `nil` when the README has no such
    ///   heading.
    /// - Throws: The error ``TextFileLines/read(from:)`` throws.
    private static func sectionLines() throws -> [String]? {
        let readme = RepositoryRoot.url().appendingPathComponent(readmePath)
        let lines = try TextFileLines.read(from: readme)
        guard let heading = lines.firstIndex(of: sectionHeading) else { return nil }
        return MarkdownSection.body(below: heading, in: lines)
    }

    @Test("the README section names every pinned symbol in backticks")
    func readmeSectionNamesEveryPinnedSymbol() throws {
        let section = try #require(
            try Self.sectionLines(), "\(Self.readmePath) has no \"\(Self.sectionHeading)\" heading."
        )
        let text = section.joined(separator: "\n")
        for symbol in Self.pinnedSymbols {
            #expect(text.contains("`\(symbol)`"), "the section does not name `\(symbol)`.")
        }
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
    func freshPoolHoldsNoModel() async {
        #expect(await ModelPool().residentModelCount == 0)
    }

    @Test("`Router(samplingMode:)` keeps the decoding strategy on the router")
    func routerKeepsItsSamplingMode() async {
        let dir = Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(cacheDir: dir, samplingMode: .greedy, pool: ModelPool())
        #expect(await router.samplingMode == .greedy)
    }
}
