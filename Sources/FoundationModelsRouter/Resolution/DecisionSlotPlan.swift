import FoundationModelsDecision
import Logging

/// The model and the decision path of the decision slot of one resolve.
///
/// The path of a decision model that is not the fallback comes in this
/// order:
///
/// 1. A GGUF model whose decision type llama.cpp supports
///    (``RepoMetadata/hasNativeDecisionType``) takes the native path. The
///    decision code of llama.cpp makes the prompt and reads the answer.
/// 2. Else a repository with a `decider_config.json` file gets
///    `DeciderPromptFormat` (``DecisionFormatLoader``).
/// 3. Else the model gets `GenericPromptFormat`, which works with any
///    instruct model.
///
/// An MLX model has no decision type, thus it uses only 2 and 3.
///
/// The flash fallback (``SlotFallback/flashModel``) reads no file. It takes
/// the native path when the flash model has a supported decision type, and
/// else it uses `GenericPromptFormat`. The decision type comes from the
/// sizing step, thus it costs no read and cannot fail, and the path of a
/// model is the same in the fallback as in the decision slot.
///
/// When the read of `decider_config.json` fails, the decision slot changes to
/// the flash fallback before any acquire, and the failure is logged. A
/// failure of the decision slot never stops the resolve.
struct DecisionSlotPlan: Sendable {
    /// The reason that the report of the decision slot records, and that the
    /// warning tells, when the format of the decision model cannot be read.
    static let formatUnavailableReason = "the prompt format of the decision model could not be read"

    /// The joint resolution that the resolve applies. Its decision slot is
    /// the flash fallback when the format of the chosen decision model could
    /// not be read.
    let resolution: JointResolution

    /// The decision path of the model of the decision slot.
    let path: DecisionPath

    /// Makes the plan of the decision slot of `resolution`.
    ///
    /// - Parameters:
    ///   - resolution: The joint fit of the resolve.
    ///   - metadataByRef: The sizing metadata of each candidate.
    ///   - source: The metadata source that reads the `decider_config.json`
    ///     file of a Hub repository.
    ///   - logger: The logger of the warning when the format cannot be read.
    /// - Returns: The plan.
    static func make(
        for resolution: JointResolution,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        source: any MetadataSource,
        logger: Logger
    ) async -> DecisionSlotPlan {
        guard let decisionSlot = resolution.slots.first(where: { $0.slot == .decision }),
            decisionSlot.fallback == nil, let chosen = decisionSlot.chosen
        else {
            return fallbackPlan(of: resolution, metadataByRef: metadataByRef)
        }
        do {
            guard case .success(let metadata) = metadataByRef[chosen] else {
                throw RepoMetadataError.metadataUnavailable("candidate \(chosen.stringValue) was not sized")
            }
            guard !metadata.hasNativeDecisionType else {
                return DecisionSlotPlan(resolution: resolution, path: .native)
            }
            let format = try await DecisionFormatLoader.format(for: chosen, metadata: metadata, source: source)
            return DecisionSlotPlan(resolution: resolution, path: .promptFormat(format))
        } catch {
            logger.warning(
                "\(formatUnavailableReason); the decision slot uses the flash model",
                metadata: RouterTelemetry.errorMetadata(error).merging(
                    [RouterTelemetry.LogMetadataKey.modelRef: "\(chosen.stringValue)"]) { _, ref in ref })
            return fallbackPlan(
                of: resolution.fallingBackToFlash(because: formatUnavailableReason), metadataByRef: metadataByRef)
        }
    }

    /// Makes the plan of a decision slot that uses the flash fallback, or
    /// that chose no model. It reads no file.
    ///
    /// - Parameters:
    ///   - resolution: The joint resolution that the resolve applies.
    ///   - metadataByRef: The sizing metadata of each candidate.
    /// - Returns: The plan: the native path when the model of the decision
    ///   slot has a supported decision type, else `GenericPromptFormat`.
    private static func fallbackPlan(
        of resolution: JointResolution, metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>]
    ) -> DecisionSlotPlan {
        guard case .success(let metadata) = metadataByRef[resolution.decision], metadata.hasNativeDecisionType else {
            return DecisionSlotPlan(resolution: resolution, path: .promptFormat(GenericPromptFormat()))
        }
        return DecisionSlotPlan(resolution: resolution, path: .native)
    }
}
