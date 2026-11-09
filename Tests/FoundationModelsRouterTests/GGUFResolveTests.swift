import Foundation
import FoundationModelsLlamaCpp
import FoundationModelsRouterTestSupport
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// Proves that a resolve sizes a GGUF candidate and its GGUF drafter before
/// any download, and chooses between an MLX candidate and a GGUF candidate on
/// fit alone. No network, no GPU: a stub source serves the tree listings and
/// the GGUF headers, and a stub loader loads.
@Suite("GGUF resolve")
struct GGUFResolveTests {
    /// The MLX standard candidate.
    private static let mlxRef: ModelRef = "org/std-mlx"

    /// The GGUF standard candidate: one quantization folder of a GGUF repo.
    private static let ggufRef = ModelRef(repo: "org/std-GGUF", path: "Q4_K_M")

    /// The path of the model file of ``ggufRef``.
    private static let ggufModelPath = "Q4_K_M/model-Q4_K_M.gguf"

    /// The GGUF drafter of the drafter tests.
    private static let drafterRef = ModelRef(repo: "org/drafter-GGUF")

    /// The path of the model file of ``drafterRef``.
    private static let drafterModelPath = "drafter.gguf"

    /// The weights of a model that fits the budget of the stub probe.
    private static let smallBytes: Int64 = 10_000_000

    /// The weights of a model larger than the budget of the stub probe.
    private static let hugeBytes: Int64 = 100_000_000_000

    /// The weights of the GGUF drafter.
    private static let drafterBytes: Int64 = 500_000

    /// The context of the footprint tests, not a multiple of 256.
    private static let context = 3_000

    /// The tree listing of the GGUF standard repo, with its model at `size`.
    private static func ggufTree(size: Int64) -> Data {
        HubTreeListing.json([
            .lfsFile(ggufModelPath, size: size),
            .lfsFile("Q8_0/model-Q8_0.gguf", size: hugeBytes),
        ])
    }

    /// The tree listing of the MLX standard repo, with one shard of `size`.
    private static func mlxTree(size: Int64) -> Data {
        HubTreeListing.json([.file("model.safetensors", size: size)])
    }

    /// A source that serves the MLX repo, the GGUF repo and the drafter
    /// repo, and the shared fixture metadata for each other repo.
    ///
    /// - Parameters:
    ///   - mlxBytes: The weights of the MLX candidate.
    ///   - ggufBytes: The weights of the GGUF candidate.
    ///   - drafterHeader: The GGUF header of the drafter.
    /// - Returns: The source.
    private static func source(
        mlxBytes: Int64, ggufBytes: Int64, drafterHeader: Data = GGUFHeaderFixtures.denseBytes
    ) -> FileServingMetadataSource {
        FileServingMetadataSource(
            rawByRepo: [
                mlxRef.repo: RawRepoMetadata(configJSON: RouterTestFixtures.configJSON, treeJSON: mlxTree(size: mlxBytes)),
                ggufRef.repo: RawRepoMetadata(configJSON: nil, treeJSON: ggufTree(size: ggufBytes)),
                drafterRef.repo: RawRepoMetadata(
                    configJSON: nil,
                    treeJSON: HubTreeListing.json([
                        .lfsFile(drafterModelPath, size: drafterBytes)
                    ])),
            ],
            defaultRaw: RouterTestFixtures.rawMetadata,
            files: [
                "\(ggufRef.repo)/\(ggufModelPath)": GGUFHeaderFixtures.hybridBytes,
                "\(drafterRef.repo)/\(drafterModelPath)": drafterHeader,
            ])
    }

    /// A profile whose standard slot lists `standard`, in order.
    ///
    /// - Parameter standard: The standard candidates.
    /// - Returns: The profile.
    private static func profile(standard: [ModelRef]) -> ProfileDefinition {
        ProfileDefinition(
            name: "gguf", description: "an MLX candidate and a GGUF candidate", standard: standard,
            flash: ["org/flash-a"], embedding: ["org/emb-a"], context: ScriptedSessionContext.tokens)
    }

    /// Resolves `profile` over `source` with the stub probe and loader.
    ///
    /// - Parameters:
    ///   - profile: The profile.
    ///   - source: The metadata source.
    ///   - logger: The explicit logger of the router, or `nil`.
    /// - Returns: The resolved profile.
    /// - Throws: What the resolve throws.
    private static func resolve(
        _ profile: ProfileDefinition, source: some MetadataSource, logger: Logger? = nil
    ) async throws -> LanguageModelProfile {
        let dir = RouterTestFixtures.makeTempDir(prefix: "GGUFResolveTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(
            cacheDir: dir, probe: RouterTestFixtures.stubProbe, metadataSource: source,
            loader: StubModelLoader(container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())
        if let logger {
            await router.useLogger(logger)
        }
        return try await router.resolve(profile: profile, reporting: ResolutionProgress())
    }

    /// The metadata of a GGUF model from a header fixture.
    ///
    /// - Parameters:
    ///   - bytes: The header bytes.
    ///   - weightBytes: The weights of the model.
    /// - Returns: The metadata.
    /// - Throws: The error of the parse.
    private static func ggufMetadata(_ bytes: Data, weightBytes: Int64) throws -> RepoMetadata {
        try RepoMetadata(ggufHeader: GGUFHeader.parse(prefix: bytes), weightBytes: weightBytes, name: "fixture")
    }

    @Test("a GGUF candidate with a GGUF drafter is charged the weights and the context of the drafter")
    func ggufDrafterIsChargedItsContext() throws {
        let ref = ModelRef(repo: Self.ggufRef.repo, path: Self.ggufRef.path, drafter: Self.drafterRef)
        let target = try Self.ggufMetadata(GGUFHeaderFixtures.hybridBytes, weightBytes: Self.smallBytes)
        let drafter = try Self.ggufMetadata(GGUFHeaderFixtures.denseBytes, weightBytes: Self.drafterBytes)

        let bytes = Router.footprintBytes(
            for: ref, context: Self.context,
            metadataByRef: [ref: .success(target), Self.drafterRef: .success(drafter)],
            membership: [ref: [.standard]], residentKeys: [])

        #expect(
            try bytes.get()
                == target.footprint.footprint(context: Self.context) + Self.drafterBytes
                + drafter.footprint.kvBytes(context: Self.context))
    }

    @Test("JointFit takes the GGUF candidate when the MLX candidate listed first does not fit")
    func ggufChosenWhenMLXDoesNotFit() async throws {
        let source = Self.source(mlxBytes: Self.hugeBytes, ggufBytes: Self.smallBytes)

        let resolved = try await Self.resolve(Self.profile(standard: [Self.mlxRef, Self.ggufRef]), source: source)

        #expect(resolved.standard.chosen == Self.ggufRef)
    }

    @Test("JointFit takes the MLX candidate when the GGUF candidate listed first does not fit")
    func mlxChosenWhenGGUFDoesNotFit() async throws {
        let source = Self.source(mlxBytes: Self.smallBytes, ggufBytes: Self.hugeBytes)

        let resolved = try await Self.resolve(Self.profile(standard: [Self.ggufRef, Self.mlxRef]), source: source)

        #expect(resolved.standard.chosen == Self.mlxRef)
    }

    @Test("a drafter whose GGUF architecture llama.cpp does not load as DFlash is still sized and chosen")
    func forkDFlashDrafterIsStillSized() async throws {
        let ref = ModelRef(repo: Self.ggufRef.repo, path: Self.ggufRef.path, drafter: Self.drafterRef)
        let source = Self.source(
            mlxBytes: Self.smallBytes, ggufBytes: Self.smallBytes,
            drafterHeader: GGUFHeaderFixtures.forkDFlashDrafterBytes)

        let resolved = try await Self.resolve(Self.profile(standard: [ref]), source: source)

        #expect(resolved.standard.chosen == ref)
    }

    @Test("a drafter whose GGUF architecture llama.cpp does not load as DFlash logs a warning that names it")
    func forkDFlashDrafterLogsAWarning() async throws {
        let ref = ModelRef(repo: Self.ggufRef.repo, path: Self.ggufRef.path, drafter: Self.drafterRef)
        let source = Self.source(
            mlxBytes: Self.smallBytes, ggufBytes: Self.smallBytes,
            drafterHeader: GGUFHeaderFixtures.forkDFlashDrafterBytes)

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await Self.resolve(Self.profile(standard: [ref]), source: source, logger: context.logger)
            return context.logRecords
        }

        #expect(
            records.contains {
                $0.level == .warning
                    && $0.metadata[RouterTelemetry.LogMetadataKey.modelRef] == "\(Self.drafterRef.stringValue)"
            })
    }

    @Test("a GGUF drafter that llama.cpp loads logs no drafter warning")
    func loadableDrafterLogsNoWarning() async throws {
        let ref = ModelRef(repo: Self.ggufRef.repo, path: Self.ggufRef.path, drafter: Self.drafterRef)
        let source = Self.source(mlxBytes: Self.smallBytes, ggufBytes: Self.smallBytes)

        let records = try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await Self.resolve(Self.profile(standard: [ref]), source: source, logger: context.logger)
            return context.logRecords
        }

        #expect(
            !records.contains {
                $0.level == .warning
                    && $0.metadata[RouterTelemetry.LogMetadataKey.modelRef] == "\(Self.drafterRef.stringValue)"
            })
    }
}
