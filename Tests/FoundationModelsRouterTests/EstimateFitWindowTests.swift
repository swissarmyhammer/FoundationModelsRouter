import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for the window of ``Router/estimateFit(of:minimumContextTokens:)``
/// (task ^h27ffj0, decision D203): a profile fits only with a window of the
/// minimum or more, and the estimate gives the window of the fit.
///
/// Each budget is the charge of the stub profile at one window, as an
/// estimate at that explicit context gives it. The charge grows linearly with
/// the window, so the largest window that fits that budget is that window.
/// The stub metadata source answers each fetch, so no test reads the network.
@Suite("Router fit estimate window")
struct EstimateFitWindowTests {
    /// The temp-directory prefix of the cache directory of each test, so a
    /// leaked directory names this suite.
    private static let tempDirPrefix = "EstimateFitWindowTests"

    /// A native window much larger than each window under test, so the
    /// budget, not the model, sets the window.
    private static let largeNativeWindow = 131_072

    /// A window over the default minimum: about 49K tokens, the window of
    /// the `small` profile on 16 GB.
    private static let windowOverTheMinimum = 49_152

    /// A window under the default minimum.
    private static let windowUnderTheMinimum = 8_192

    /// A native window under the default minimum.
    private static let smallNativeWindow = 16_384

    /// The `config.json` of the stub model of ``RouterTestFixtures`` with
    /// another native window.
    ///
    /// - Parameter nativeWindow: The `max_position_embeddings` of the model.
    /// - Returns: The metadata of the model.
    private static func rawMetadata(nativeWindow: Int) -> RawRepoMetadata {
        let config = Data(
            """
            {
                "num_hidden_layers": \(RouterTestFixtures.layerCount),
                "max_position_embeddings": \(nativeWindow),
                "num_attention_heads": \(RouterTestFixtures.attentionHeadCount),
                "num_key_value_heads": \(RouterTestFixtures.keyValueHeadCount),
                "head_dim": \(RouterTestFixtures.headDimension),
                "hidden_size": \(RouterTestFixtures.hiddenSize)
            }
            """.utf8)
        return RawRepoMetadata(configJSON: config, treeJSON: RouterTestFixtures.treeJSON)
    }

    /// A router over stub metadata with the native window `nativeWindow`
    /// and the machine budget `budgetBytes`.
    ///
    /// - Parameters:
    ///   - nativeWindow: The native window of each stub model.
    ///   - budgetBytes: The machine budget.
    ///   - cacheDir: The cache directory of the router.
    /// - Returns: The router.
    private static func makeRouter(nativeWindow: Int, budgetBytes: Int64, cacheDir: URL) -> Router {
        Router(
            cacheDir: cacheDir, recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: budgetBytes, recommendedMaxWorkingSetSize: budgetBytes),
            metadataSource: StubMetadataSource(raw: rawMetadata(nativeWindow: nativeWindow)),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
    }

    /// The bytes that the stub profile charges at the explicit context
    /// `window`: the budget whose largest window is `window`.
    ///
    /// - Parameters:
    ///   - window: The window.
    ///   - cacheDir: The cache directory of the router.
    /// - Returns: The bytes.
    /// - Throws: When the estimate at `window` does not fit.
    private static func budget(forWindow window: Int, cacheDir: URL) async throws -> Int64 {
        let router = makeRouter(
            nativeWindow: largeNativeWindow, budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: cacheDir)
        return try #require(await router.estimateFit(of: RouterTestFixtures.profile(context: window)).requiredBytes)
    }

    /// The estimate of the stub profile with a derived window, against the
    /// budget whose largest window is `window`.
    ///
    /// - Parameters:
    ///   - window: The largest window that the budget holds.
    ///   - minimumContextTokens: The minimum window of the estimate.
    /// - Returns: The estimate.
    /// - Throws: When the budget cannot be measured.
    private static func estimate(
        atBudgetOfWindow window: Int,
        minimumContextTokens: Int = ProfileFitEstimate.defaultMinimumContextTokens
    ) async throws -> ProfileFitEstimate {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let budgetBytes = try await budget(forWindow: window, cacheDir: dir)
        let router = makeRouter(nativeWindow: largeNativeWindow, budgetBytes: budgetBytes, cacheDir: dir)
        return await router.estimateFit(
            of: RouterTestFixtures.profile(context: nil), minimumContextTokens: minimumContextTokens)
    }

    @Test("A budget with a window over the minimum fits at the largest window")
    func windowOverTheMinimumFits() async throws {
        let estimate = try await Self.estimate(atBudgetOfWindow: Self.windowOverTheMinimum)

        #expect(estimate.fits && estimate.contextTokens == Self.windowOverTheMinimum)
    }

    @Test("A budget with a window under the minimum does not fit")
    func windowUnderTheMinimumDoesNotFit() async throws {
        let estimate = try await Self.estimate(atBudgetOfWindow: Self.windowUnderTheMinimum)

        #expect(!estimate.fits && estimate.contextTokens == nil)
    }

    @Test("The failure names the largest window that fits and the minimum")
    func failureNamesTheWindowAndTheMinimum() async throws {
        let estimate = try await Self.estimate(atBudgetOfWindow: Self.windowUnderTheMinimum)

        #expect(
            estimate.failure == "the largest window that fits is 8,192 tokens; a profile needs 32,768")
    }

    @Test("A smaller minimum lets a small window fit")
    func smallerMinimumLetsASmallWindowFit() async throws {
        let estimate = try await Self.estimate(
            atBudgetOfWindow: Self.windowUnderTheMinimum, minimumContextTokens: Self.windowUnderTheMinimum)

        #expect(estimate.fits && estimate.contextTokens == Self.windowUnderTheMinimum)
    }

    @Test("A native window under the minimum fits at the native window")
    func nativeWindowUnderTheMinimumFits() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(
            nativeWindow: Self.smallNativeWindow, budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile(context: nil))

        #expect(estimate.fits && estimate.contextTokens == Self.smallNativeWindow)
    }

    @Test("A failure under a native window smaller than the minimum names the native window")
    func failureNamesTheNativeWindowUnderTheMinimum() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let budgetBytes = try await Self.budget(forWindow: Self.windowUnderTheMinimum, cacheDir: dir)
        let router = Self.makeRouter(nativeWindow: Self.smallNativeWindow, budgetBytes: budgetBytes, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile(context: nil))

        #expect(estimate.failure == "the largest window that fits is 8,192 tokens; a profile needs 16,384")
    }

    @Test("An explicit context is the window of the fit")
    func explicitContextIsTheWindow() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(
            nativeWindow: Self.largeNativeWindow, budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile(context: Self.windowUnderTheMinimum))

        #expect(estimate.fits && estimate.contextTokens == Self.windowUnderTheMinimum)
    }

    @Test("A resolve with a budget under the minimum loads at the largest window")
    @MainActor
    func resolveKeepsTheLargestWindowUnderTheMinimum() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let budgetBytes = try await Self.budget(forWindow: Self.windowUnderTheMinimum, cacheDir: dir)
        let router = Self.makeRouter(nativeWindow: Self.largeNativeWindow, budgetBytes: budgetBytes, cacheDir: dir)

        let resolved = try await router.resolve(
            profile: RouterTestFixtures.profile(context: nil), reporting: ResolutionProgress())

        #expect(resolved.standard.contextTokens == Self.windowUnderTheMinimum)
    }
}
