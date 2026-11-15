import Foundation
import FoundationModelsDecision
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of ``DecisionSlotPlan``: the decision path of the decision slot of a
/// resolve. A GGUF model with a decision type that llama.cpp supports takes
/// the native path. Else a model with `decider_config.json` gets the decider
/// format, and any other model gets the generic format. When the read of the
/// format fails, the plan throws ``DecisionFormatFailure`` (task ^ybx7vvn).
/// No network: a stub source answers each read.
@Suite("The decision path of the decision slot of a resolve")
struct DecisionSlotPlanTests {
    // MARK: - Fixed values

    /// The name of the configuration file of a decider repository.
    private static let configurationFileName = "decider_config.json"

    /// The standard model of each resolution.
    private static let standardRef: ModelRef = "org/standard"

    /// The flash model of each resolution.
    private static let flashRef: ModelRef = "org/flash"

    /// The embedding model of each resolution.
    private static let embeddingRef: ModelRef = "org/embedding"

    /// The decision model of each resolution.
    private static let deciderRef: ModelRef = "org/decider"

    /// The raw footprint of the decision model.
    private static let deciderFootprintBytes: Int64 = 3_000

    /// A small `decider_config.json` file.
    private static let deciderConfigJSON = Data(#"{"layout": "plain", "isolated_levels": false}"#.utf8)

    /// A `config.json` with a small attention shape.
    private static let modelConfigJSON = Data(
        """
        {"num_hidden_layers": 2, "num_attention_heads": 8, "head_dim": 16, "max_position_embeddings": 4096}
        """.utf8)

    /// The size of the weights of the decider repository.
    private static let weightBytes: Int64 = 1_000

    /// A decision type that llama.cpp knows, but that its `decide` does not
    /// support: the type reads an image.
    private static let imageDecisionType = "openbmb-minicpm-ocr-jev"

    /// A decision type that llama.cpp does not know.
    private static let unknownDecisionType = "a-later-decision-type"

    /// The layers of the GGUF decision model.
    private static let ggufLayers = 2

    /// The attention heads of the GGUF decision model.
    private static let ggufAttentionHeads = 8

    /// The training context of the GGUF decision model.
    private static let ggufContext = 4_096

    // MARK: - Helpers

    /// A slot resolution of the trio that chose `ref`.
    ///
    /// - Parameters:
    ///   - slot: The slot.
    ///   - ref: The chosen model.
    /// - Returns: The slot resolution.
    private static func trioSlot(_ slot: ModelSlot, chose ref: ModelRef) -> SlotResolution {
        SlotResolution(
            slot: slot, remainingBudgetBytes: 0, chosen: ref,
            considered: [CandidateReport(ref: ref, estimatedFootprintBytes: 0, chargedBytes: 0, verdict: .chosen)],
            contextTokens: ScriptedSessionContext.tokens)
    }

    /// A joint resolution whose decision slot is `decision`.
    ///
    /// - Parameters:
    ///   - decisionRef: The model of the decision slot.
    ///   - decision: The resolution of the decision slot.
    /// - Returns: The joint resolution.
    private static func resolution(decisionRef: ModelRef, decision: SlotResolution) -> JointResolution {
        JointResolution(
            embedding: embeddingRef, standard: standardRef, flash: flashRef, decision: decisionRef,
            slots: [
                trioSlot(.embedding, chose: embeddingRef), trioSlot(.standard, chose: standardRef),
                trioSlot(.flash, chose: flashRef), decision,
            ])
    }

    /// A joint resolution whose decision slot chose ``deciderRef``.
    private static var deciderResolution: JointResolution {
        resolution(
            decisionRef: deciderRef,
            decision: SlotResolution(
                slot: .decision, remainingBudgetBytes: 0, chosen: deciderRef,
                considered: [
                    CandidateReport(
                        ref: deciderRef, estimatedFootprintBytes: deciderFootprintBytes,
                        chargedBytes: deciderFootprintBytes, verdict: .chosen)
                ],
                contextTokens: ScriptedSessionContext.tokens))
    }

    /// The metadata of the decider repository, with a `decider_config.json`
    /// file of the size of ``deciderConfigJSON``.
    ///
    /// - Returns: The metadata of ``deciderRef``, by its ref.
    /// - Throws: The error of the parse.
    private static func deciderMetadata() throws -> [ModelRef: Result<RepoMetadata, RepoMetadataError>] {
        [deciderRef: .success(try mlxMetadata(hasDeciderConfiguration: true))]
    }

    /// The metadata of an MLX decision model, as the parse of its tree gives it.
    ///
    /// - Parameter hasDeciderConfiguration: Whether the repository has a
    ///   `decider_config.json` file of the size of ``deciderConfigJSON``.
    /// - Returns: The metadata.
    /// - Throws: The error of the parse.
    private static func mlxMetadata(hasDeciderConfiguration: Bool) throws -> RepoMetadata {
        var entries: [HubTreeListing.Entry] = [.file("model.safetensors", size: weightBytes)]
        if hasDeciderConfiguration {
            entries.append(.file(configurationFileName, size: Int64(deciderConfigJSON.count)))
        }
        return try RepoMetadata(
            raw: RawRepoMetadata(configJSON: modelConfigJSON, treeJSON: HubTreeListing.json(entries)),
            repo: deciderRef.repo)
    }

    /// The metadata of a GGUF decision model, as the sizing step records it.
    ///
    /// - Parameters:
    ///   - decisionType: The decision type of the GGUF header, or `nil` for
    ///     a header with no decision type.
    ///   - hasDeciderConfiguration: Whether the repository has a
    ///     `decider_config.json` file of the size of ``deciderConfigJSON``.
    /// - Returns: The metadata.
    private static func ggufMetadata(decisionType: String?, hasDeciderConfiguration: Bool = false) -> RepoMetadata {
        RepoMetadata(
            weightBytes: weightBytes, numHiddenLayers: ggufLayers, numAttentionHeads: ggufAttentionHeads,
            numKeyValueHeads: nil, headDim: nil, hiddenSize: nil, nativeMaxContext: ggufContext,
            deciderConfigurationByteCount: hasDeciderConfiguration ? Int64(deciderConfigJSON.count) : nil,
            ggufDecisionType: decisionType)
    }

    /// Makes the plan of `resolution` over a source that holds `files`.
    ///
    /// - Parameters:
    ///   - resolution: The joint resolution.
    ///   - files: The bytes of each file of the source, by its path.
    /// - Returns: The plan, and the source.
    /// - Throws: The error of the metadata parse.
    private static func plan(
        of resolution: JointResolution, files: [String: Data]
    ) async throws -> (plan: DecisionSlotPlan, source: DecisionFormatLoaderTests.RecordingFileSource) {
        try await plan(of: resolution, metadataByRef: deciderMetadata(), files: files)
    }

    /// Makes the plan of `resolution` with `metadataByRef`, over a source
    /// that holds `files`.
    ///
    /// - Parameters:
    ///   - resolution: The joint resolution.
    ///   - metadataByRef: The sizing metadata of each candidate.
    ///   - files: The bytes of each file of the source, by its path.
    /// - Returns: The plan, and the source.
    /// - Throws: ``DecisionFormatFailure`` when the format cannot be read.
    private static func plan(
        of resolution: JointResolution, metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        files: [String: Data] = [:]
    ) async throws -> (plan: DecisionSlotPlan, source: DecisionFormatLoaderTests.RecordingFileSource) {
        let source = DecisionFormatLoaderTests.RecordingFileSource(files: files)
        let plan = try await DecisionSlotPlan.make(for: resolution, metadataByRef: metadataByRef, source: source)
        return (plan, source)
    }

    /// Makes the plan of ``deciderResolution`` when the decision model has
    /// `metadata`, over a source that holds `decider_config.json`.
    ///
    /// - Parameter metadata: The metadata of ``deciderRef``.
    /// - Returns: The plan, and the source.
    /// - Throws: ``DecisionFormatFailure`` when the format cannot be read.
    private static func deciderPlan(
        metadata: RepoMetadata
    ) async throws -> (plan: DecisionSlotPlan, source: DecisionFormatLoaderTests.RecordingFileSource) {
        try await plan(
            of: deciderResolution, metadataByRef: [deciderRef: .success(metadata)],
            files: [configurationFileName: deciderConfigJSON])
    }

    // MARK: - A decision model

    @Test("a decision model with decider_config.json gets the decider format")
    func decisionModelGetsTheDeciderFormat() async throws {
        let (plan, _) = try await Self.plan(
            of: Self.deciderResolution, files: [Self.configurationFileName: Self.deciderConfigJSON])

        #expect(plan.path.promptFormat is DeciderPromptFormat)
    }

    @Test("a GGUF decision model with a supported decision type takes the native path")
    func supportedDecisionTypeTakesTheNativePath() async throws {
        let (plan, _) = try await Self.deciderPlan(metadata: Self.ggufMetadata(decisionType: GGUFHeaderFixtures.supportedDecisionType))

        #expect(plan.path.isNative)
    }

    @Test("a supported decision type takes the native path also when the repository has decider_config.json")
    func supportedDecisionTypeWinsOverDeciderConfiguration() async throws {
        let (plan, _) = try await Self.deciderPlan(
            metadata: Self.ggufMetadata(decisionType: GGUFHeaderFixtures.supportedDecisionType, hasDeciderConfiguration: true))

        #expect(plan.path.isNative)
    }

    @Test("the native path reads no decider_config.json file")
    func nativePathReadsNoFile() async throws {
        let (_, source) = try await Self.deciderPlan(
            metadata: Self.ggufMetadata(decisionType: GGUFHeaderFixtures.supportedDecisionType, hasDeciderConfiguration: true))

        #expect(await source.fetches.isEmpty)
    }

    @Test("a decision type that decide does not support uses decider_config.json")
    func unsupportedDecisionTypeGetsTheDeciderFormat() async throws {
        let (plan, _) = try await Self.deciderPlan(
            metadata: Self.ggufMetadata(decisionType: Self.imageDecisionType, hasDeciderConfiguration: true))

        #expect(plan.path.promptFormat is DeciderPromptFormat)
    }

    @Test("a decision type that llama.cpp does not know, with no decider_config.json, gets the generic format")
    func unknownDecisionTypeGetsTheGenericFormat() async throws {
        let (plan, _) = try await Self.deciderPlan(metadata: Self.ggufMetadata(decisionType: Self.unknownDecisionType))

        #expect(plan.path.promptFormat is GenericPromptFormat)
    }

    @Test("a GGUF decision model with no decision type and no decider_config.json gets the generic format")
    func ggufWithNoDecisionTypeGetsTheGenericFormat() async throws {
        let (plan, _) = try await Self.deciderPlan(metadata: Self.ggufMetadata(decisionType: nil))

        #expect(plan.path.promptFormat is GenericPromptFormat)
    }

    @Test("an MLX decision model with no decider_config.json gets the generic format")
    func mlxWithNoDeciderConfigurationGetsTheGenericFormat() async throws {
        let (plan, _) = try await Self.deciderPlan(metadata: try Self.mlxMetadata(hasDeciderConfiguration: false))

        #expect(plan.path.promptFormat is GenericPromptFormat)
    }

    @Test("a decision model whose format loads keeps its resolution")
    func decisionModelKeepsItsResolution() async throws {
        let (plan, _) = try await Self.plan(
            of: Self.deciderResolution, files: [Self.configurationFileName: Self.deciderConfigJSON])

        #expect(plan.resolution == Self.deciderResolution)
    }

    // MARK: - A failed format load

    @Test("a failed format load fails the plan, and the failure names the decision model")
    func failedFormatLoadFailsThePlan() async throws {
        let failure = try await #require(throws: DecisionFormatFailure.self) {
            _ = try await Self.plan(of: Self.deciderResolution, files: [:])
        }

        #expect(failure.model == Self.deciderRef)
        #expect(failure.description.contains(Self.deciderRef.stringValue))
    }

    @Test("a decision model with no sizing metadata fails the plan")
    func unsizedDecisionModelFailsThePlan() async throws {
        let failure = try await #require(throws: DecisionFormatFailure.self) {
            _ = try await Self.plan(of: Self.deciderResolution, metadataByRef: [:])
        }

        #expect(failure.model == Self.deciderRef)
    }
}

extension DecisionPath {
    /// The prompt format of the path, or `nil` for the native path.
    fileprivate var promptFormat: (any DecisionPromptFormat)? {
        guard case .promptFormat(let format) = self else { return nil }
        return format
    }

    /// Whether the path is the native path.
    fileprivate var isNative: Bool {
        guard case .native = self else { return false }
        return true
    }
}
