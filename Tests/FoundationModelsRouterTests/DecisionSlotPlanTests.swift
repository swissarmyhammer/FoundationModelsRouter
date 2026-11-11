import Foundation
import FoundationModelsDecision
import FoundationModelsRouterTestSupport
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// Tests of ``DecisionSlotPlan``: the prompt format of the decision slot of a
/// resolve. The flash fallback uses the generic format and reads no file. A
/// decision model that is not the fallback gets its format from its
/// repository. When that read fails, the decision slot changes to the flash
/// fallback. No network: a stub source answers each read.
@Suite("The prompt format of the decision slot of a resolve")
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

    /// The decision model of a resolution that is not the flash fallback.
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

    /// A joint resolution whose decision slot uses the flash fallback.
    private static var fallbackResolution: JointResolution {
        resolution(
            decisionRef: flashRef,
            decision: SlotResolution(
                slot: .decision, remainingBudgetBytes: 0, chosen: flashRef,
                considered: [
                    CandidateReport(
                        ref: deciderRef, estimatedFootprintBytes: deciderFootprintBytes,
                        chargedBytes: deciderFootprintBytes, verdict: .tooLarge)
                ],
                contextTokens: ScriptedSessionContext.tokens, fallback: .flashModel))
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
        let tree = HubTreeListing.json([
            .file("model.safetensors", size: weightBytes),
            .file(configurationFileName, size: Int64(deciderConfigJSON.count)),
        ])
        let metadata = try RepoMetadata(
            raw: RawRepoMetadata(configJSON: modelConfigJSON, treeJSON: tree), repo: deciderRef.repo)
        return [deciderRef: .success(metadata)]
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
        let source = DecisionFormatLoaderTests.RecordingFileSource(files: files)
        let plan = await DecisionSlotPlan.make(
            for: resolution, metadataByRef: try deciderMetadata(), source: source,
            logger: RouterTelemetry.makeLogger(.repoMetadataReader))
        return (plan, source)
    }

    /// The resolution of the decision slot of `resolution`.
    ///
    /// - Parameter resolution: The joint resolution.
    /// - Returns: The decision slot.
    /// - Throws: When `resolution` has no decision slot.
    private static func decisionSlot(of resolution: JointResolution) throws -> SlotResolution {
        try #require(resolution.slots.first { $0.slot == .decision })
    }

    // MARK: - The flash fallback

    @Test("the flash fallback uses the generic format")
    func flashFallbackUsesTheGenericFormat() async throws {
        let (plan, _) = try await Self.plan(of: Self.fallbackResolution, files: [:])

        #expect(plan.format is GenericPromptFormat)
    }

    @Test("the flash fallback reads no file")
    func flashFallbackReadsNoFile() async throws {
        let (_, source) = try await Self.plan(of: Self.fallbackResolution, files: [:])

        #expect(await source.fetches.isEmpty)
    }

    // MARK: - A decision model

    @Test("a decision model with decider_config.json gets the decider format")
    func decisionModelGetsTheDeciderFormat() async throws {
        let (plan, _) = try await Self.plan(
            of: Self.deciderResolution, files: [Self.configurationFileName: Self.deciderConfigJSON])

        #expect(plan.format is DeciderPromptFormat)
    }

    @Test("a decision model whose format loads keeps its resolution")
    func decisionModelKeepsItsResolution() async throws {
        let (plan, _) = try await Self.plan(
            of: Self.deciderResolution, files: [Self.configurationFileName: Self.deciderConfigJSON])

        #expect(plan.resolution == Self.deciderResolution)
    }

    // MARK: - A failed format load

    @Test("a failed format load changes the decision model to the flash winner")
    func failedFormatLoadUsesTheFlashWinner() async throws {
        let (plan, _) = try await Self.plan(of: Self.deciderResolution, files: [:])

        #expect(plan.resolution.decision == Self.flashRef)
    }

    @Test("a failed format load records the flash fallback in the decision slot")
    func failedFormatLoadRecordsTheFlashFallback() async throws {
        let (plan, _) = try await Self.plan(of: Self.deciderResolution, files: [:])
        let slot = try Self.decisionSlot(of: plan.resolution)

        #expect(slot.chosen == Self.flashRef)
        #expect(slot.fallback == .flashModel)
    }

    @Test("a failed format load records why the decision model was not used")
    func failedFormatLoadRecordsTheReason() async throws {
        let (plan, _) = try await Self.plan(of: Self.deciderResolution, files: [:])
        let candidate = try #require(try Self.decisionSlot(of: plan.resolution).considered.first)

        #expect(candidate.ref == Self.deciderRef)
        #expect(candidate.verdict == .metadataUnavailable(DecisionSlotPlan.formatUnavailableReason))
    }

    @Test("a failed format load uses the generic format")
    func failedFormatLoadUsesTheGenericFormat() async throws {
        let (plan, _) = try await Self.plan(of: Self.deciderResolution, files: [:])

        #expect(plan.format is GenericPromptFormat)
    }

    @Test("a failed format load writes a warning")
    func failedFormatLoadWritesAWarning() async throws {
        try await TelemetryCapture.run(forbidding: []) { context in
            _ = try await Self.plan(of: Self.deciderResolution, files: [:])
            context.expectLogged(
                containing: DecisionSlotPlan.formatUnavailableReason,
                metadata: [RouterTelemetry.LogMetadataKey.modelRef: Self.deciderRef.stringValue])
        }
    }
}
