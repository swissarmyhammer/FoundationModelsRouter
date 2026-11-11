import FoundationModelsDecision
import Logging

/// The model and the prompt format of the decision slot of one resolve.
///
/// The flash fallback (``SlotFallback/flashModel``) uses
/// `GenericPromptFormat`, which works with any instruct model, and reads no
/// file. A decision model that is not the fallback gets its format from its
/// repository (``DecisionFormatLoader``). When that read fails, the decision
/// slot changes to the flash fallback before any acquire, and the failure is
/// logged. A failure of the decision slot never stops the resolve.
struct DecisionSlotPlan: Sendable {
    /// The reason that the report of the decision slot records, and that the
    /// warning tells, when the format of the decision model cannot be read.
    static let formatUnavailableReason = "the prompt format of the decision model could not be read"

    /// The joint resolution that the resolve applies. Its decision slot is
    /// the flash fallback when the format of the chosen decision model could
    /// not be read.
    let resolution: JointResolution

    /// The prompt format of the model of the decision slot.
    let format: any DecisionPromptFormat

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
            return DecisionSlotPlan(resolution: resolution, format: GenericPromptFormat())
        }
        do {
            guard case .success(let metadata) = metadataByRef[chosen] else {
                throw RepoMetadataError.metadataUnavailable("candidate \(chosen.stringValue) was not sized")
            }
            let format = try await DecisionFormatLoader.format(for: chosen, metadata: metadata, source: source)
            return DecisionSlotPlan(resolution: resolution, format: format)
        } catch {
            logger.warning(
                "\(formatUnavailableReason); the decision slot uses the flash model",
                metadata: RouterTelemetry.errorMetadata(error).merging(
                    [RouterTelemetry.LogMetadataKey.modelRef: "\(chosen.stringValue)"]) { _, ref in ref })
            return DecisionSlotPlan(
                resolution: resolution.fallingBackToFlash(because: formatUnavailableReason),
                format: GenericPromptFormat())
        }
    }
}
