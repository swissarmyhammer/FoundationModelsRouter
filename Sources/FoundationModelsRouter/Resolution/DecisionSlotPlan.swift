import FoundationModelsDecision

/// The model and the decision path of the decision slot of one resolve.
///
/// The path of the decision model comes in this order:
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
/// The decision slot is required (task ^ybx7vvn). When the read of
/// `decider_config.json` fails, the resolve fails with
/// ``DecisionFormatFailure`` before any acquire: the slot never uses another
/// model, or another format, in place of the one the repository states.
struct DecisionSlotPlan: Sendable {
    /// The joint resolution that the resolve applies.
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
    /// - Returns: The plan.
    /// - Throws: ``DecisionFormatFailure`` when the decision model was not
    ///   sized, or when its `decider_config.json` file cannot be read.
    static func make(
        for resolution: JointResolution,
        metadataByRef: [ModelRef: Result<RepoMetadata, RepoMetadataError>],
        source: any MetadataSource
    ) async throws -> DecisionSlotPlan {
        let chosen = resolution.decision
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
            throw DecisionFormatFailure(model: chosen, underlyingError: error)
        }
    }
}

/// The error thrown when the prompt format of the chosen decision model
/// cannot be read (``DecisionSlotPlan``). The resolve fails, because the
/// decision slot is required.
struct DecisionFormatFailure: Error, CustomStringConvertible {
    /// The decision model whose format could not be read.
    let model: ModelRef

    /// The error of the read.
    let underlyingError: any Error

    /// A one-line rendering that names the model and the error.
    var description: String {
        "DecisionFormatFailure: the prompt format of the decision model \(model.stringValue) "
            + "could not be read: \(underlyingError)"
    }
}
