import Foundation
import Testing

@testable import FoundationModelsRouter

/// The sanity numbers of the profile research of decision D203 (task
/// ^h27ffj0): the fit estimate of the bundled profiles of the ACP agent on a
/// 16 GB Mac, sized from the real metadata of each repository.
///
/// The stub metadata source serves the sizing keys and the weight sizes of
/// each repository (``QwenRepoFixtures``) and the GGUF header of the decision
/// model (``GGUFHeaderFixtures/h2oLightningBytes``), so no test reads the
/// network or downloads a model.
@Suite("Profile fit sanity numbers")
struct ProfileFitSanityTests {
    /// The temp-directory prefix of the cache directory of each test, so a
    /// leaked directory names this suite.
    private static let tempDirPrefix = "ProfileFitSanityTests"

    /// The RAM of a 16 GB Mac, the minimum Mac of the profiles.
    private static let ramOf16GB: Int64 = 16 << 30

    /// The GPU working set of a 16 GB Mac: two thirds of its RAM (10,922
    /// MiB), the share that macOS gives a machine of that size.
    private static let workingSetOf16GB: Int64 = ramOf16GB * 2 / 3

    /// The windows of the `small` profile on 16 GB that agree with the
    /// research: about 49K tokens, with a tolerance of about 15 percent. The
    /// sizing of these fixtures gave 52,196 tokens on 2026-11-18. A window
    /// under the default minimum of 32K is not in the range.
    private static let smallProfileWindows = 42_000...56_000

    /// The Qwen3.8 27B 4-bit model with its MTP head.
    private static let qwen38TwentySevenB = ModelRef(
        repo: "mlx-community/Qwen3.8-27B-4bit", drafter: "mlx-community/Qwen3.8-27B-MTP-4bit")

    /// The Qwen3.5 9B 4-bit model with its MTP head.
    private static let qwen35NineB = ModelRef(
        repo: "mlx-community/Qwen3.5-9B-4bit", drafter: "mlx-community/Qwen3.5-9B-MTP-4bit")

    /// The embedding model of the bundled profiles.
    private static let embeddingRef: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// A profile of the ACP agent: `generation` in the standard and the flash
    /// slots, the bundled embedding model, the default decision model
    /// (h2o-lightning-4b), and no context.
    ///
    /// - Parameters:
    ///   - name: The name of the profile.
    ///   - generation: The model of the standard and the flash slots.
    ///   - kvCache: How the language models store their KV cache.
    /// - Returns: The profile.
    private static func profile(
        named name: String, generation: ModelRef, kvCache: KVCacheQuantization?
    ) -> ProfileDefinition {
        ProfileDefinition(
            name: name, description: "the bundled profile \(name) of the ACP agent", standard: [generation],
            flash: [generation], embedding: [embeddingRef], context: nil, kvCacheQuantization: kvCache)
    }

    /// The metadata of each MLX repository of the profiles.
    private static let mlxMetadata: [String: RawRepoMetadata] = [
        "mlx-community/Qwen3.8-27B-4bit": QwenRepoFixtures.qwen38TwentySevenB4Bit,
        "mlx-community/Qwen3.8-27B-MTP-4bit": QwenRepoFixtures.qwen38TwentySevenBMTP4Bit,
        "mlx-community/Qwen3.5-9B-4bit": QwenRepoFixtures.qwen35NineB4Bit,
        "mlx-community/Qwen3.5-9B-MTP-4bit": QwenRepoFixtures.qwen35NineBMTP4Bit,
        embeddingRef.repo: QwenRepoFixtures.qwen3Embedding4Bit,
    ]

    /// The metadata of each repository of the profiles, with the GGUF file of
    /// each default decision model.
    ///
    /// - Returns: The source.
    /// - Throws: When a default decision model names no file.
    private static func makeMetadataSource() throws -> FileServingMetadataSource {
        var raw = mlxMetadata
        var files: [String: Data] = [:]
        for decision in ProfileDefinition.defaultDecisionCandidates {
            let path = try #require(decision.path)
            raw[decision.repo] = RawRepoMetadata(
                configJSON: nil,
                treeJSON: HubTreeListing.json([.lfsFile(path, size: GGUFHeaderFixtures.h2oLightningFileBytes)]))
            files["\(decision.repo)/\(path)"] = GGUFHeaderFixtures.h2oLightningBytes
        }
        return FileServingMetadataSource(rawByRepo: raw, defaultRaw: RouterTestFixtures.rawMetadata, files: files)
    }

    /// The estimate of `profile` on a 16 GB Mac.
    ///
    /// - Parameter profile: The profile.
    /// - Returns: The estimate.
    /// - Throws: When the metadata source cannot be made.
    private static func estimateOn16GB(_ profile: ProfileDefinition) async throws -> ProfileFitEstimate {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(
            cacheDir: dir, recorder: InMemoryRecorder(),
            probe: StubProbe(chip: "Apple Test", totalRAM: ramOf16GB, recommendedMaxWorkingSetSize: workingSetOf16GB),
            metadataSource: try makeMetadataSource(),
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
        return await router.estimateFit(of: profile)
    }

    @Test("small (Qwen3.5 9B 4-bit, kvBits 8, h2o decision model) fits 16 GB with about 49K tokens")
    func smallProfileFits16GB() async throws {
        let estimate = try await Self.estimateOn16GB(
            Self.profile(named: "small", generation: Self.qwen35NineB, kvCache: .bits8))

        let window = try #require(estimate.contextTokens, "\(estimate.failure ?? "")")
        #expect(Self.smallProfileWindows.contains(window), "window \(window)")
    }

    @Test("medium (Qwen3.8 27B 4-bit) does not fit 16 GB")
    func mediumProfileDoesNotFit16GB() async throws {
        let estimate = try await Self.estimateOn16GB(
            Self.profile(named: "medium", generation: Self.qwen38TwentySevenB, kvCache: nil))

        #expect(!estimate.fits)
    }
}
