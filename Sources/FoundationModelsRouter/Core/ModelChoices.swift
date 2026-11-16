/// The builtin models that each slot of a profile can take: the list of a
/// settings pane, which the router owns so that a host keeps no list of its
/// own.
///
/// ``ProfileDefinition/choices(for:)`` puts the candidates of a profile
/// before these choices. The lists name each model by its reference only:
/// they make no download and no network request, and they state no size.
/// ``ModelStorageSource/storageSummary(of:)`` reads the size of a choice at
/// run time (``ModelStorageSummary/totalBytes``).
///
/// A choice applies at the next resolve of the profile, and not at the next
/// session (see ``ProfileDefinition/slotModel(for:)``).
public enum ModelChoices {
    /// The builtin choices of a generation slot (`standard` and `flash`),
    /// from the largest model to the smallest:
    ///
    /// - `mlx-community/Qwen3.8-27B-4bit` with its MTP head
    ///   `mlx-community/Qwen3.8-27B-MTP-4bit` as the drafter: the default
    ///   model of a host.
    /// - `mlx-community/Qwen3-14B-4bit`.
    /// - `mlx-community/Qwen3-8B-4bit`.
    /// - `mlx-community/Qwen3-4B-4bit`.
    ///
    /// Each choice after the default is a smaller model than the default.
    /// This list states no size: ``ModelStorageSummary/totalBytes`` of
    /// ``ModelStorageSource/storageSummary(of:)`` gives the download size of
    /// each choice at run time.
    ///
    /// The `flash` slot takes the same models as the `standard` slot. When
    /// the two slots name the same model, the resolve loads it one time.
    public static let generation: [ModelRef] = [
        ModelRef(repo: "mlx-community/Qwen3.8-27B-4bit", drafter: "mlx-community/Qwen3.8-27B-MTP-4bit"),
        "mlx-community/Qwen3-14B-4bit",
        "mlx-community/Qwen3-8B-4bit",
        "mlx-community/Qwen3-4B-4bit",
    ]

    /// The builtin choices of the `embedding` slot:
    ///
    /// - `erjigit17/embeddinggemma-300m-ane-coreml`, a Core ML model for the
    ///   Neural Engine.
    /// - `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ`, an MLX model.
    public static let embedding: [ModelRef] = [
        "erjigit17/embeddinggemma-300m-ane-coreml",
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
    ]

    /// The builtin choices of the `decision` slot: the default decision
    /// candidates (``ProfileDefinition/defaultDecisionCandidates``).
    public static let decision: [ModelRef] = ProfileDefinition.defaultDecisionCandidates

    /// The builtin choices of a slot.
    ///
    /// - Parameter slot: The slot.
    /// - Returns: ``generation`` for `standard` and `flash`, ``embedding``
    ///   for `embedding`, and ``decision`` for `decision`.
    public static func builtin(for slot: ModelSlot) -> [ModelRef] {
        switch slot {
        case .standard, .flash: generation
        case .embedding: embedding
        case .decision: decision
        }
    }
}
