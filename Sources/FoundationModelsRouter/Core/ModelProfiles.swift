/// The builtin named profiles of the router: the list of profiles that a host
/// shows, which the router owns so that a host keeps no list of its own.
///
/// The list has four profiles, from the largest model to the smallest:
///
/// - `large`: `mlx-community/Qwen3.8-27B-4bit` with its MTP head
///   `mlx-community/Qwen3.8-27B-MTP-4bit` as the drafter. This is the
///   default profile (``defaultName``).
/// - `medium`: `mlx-community/Qwen3-14B-4bit`.
/// - `small`: `mlx-community/Qwen3-8B-4bit`.
/// - `tiny`: `mlx-community/Qwen3-4B-4bit`.
///
/// Each profile has one candidate in each slot. The `flash` slot names the
/// model of the `standard` slot, with the same drafter, so the resolve loads
/// that model one time. The `embedding` slot names the first builtin
/// embedding choice, and the `decision` slot has
/// ``ProfileDefinition/defaultDecisionCandidates``. Each profile has the
/// default decision context (``ProfileDefinition/defaultDecisionContext``)
/// and no context override.
///
/// The models come from ``ModelChoices``, so the two lists cannot drift. The
/// list states no size: ``ModelStorageSource/storageSummary(of:)`` reads the
/// size of a model at run time.
public enum ModelProfiles {
    /// The name of the default profile: `large`.
    public static let defaultName = "large"

    /// The builtin profiles, from the largest model to the smallest.
    public static let builtin: [ProfileDefinition] = zip(summaries, ModelChoices.generation).map { summary, model in
        makeProfile(name: summary.name, description: summary.description, model: model)
    }

    /// Finds the builtin profile that has a name.
    ///
    /// The match is exact: a profile name is an identifier, and not text
    /// for a person to type.
    ///
    /// - Parameter name: The name of the profile, for example a name that a
    ///   host stored in its settings.
    /// - Returns: The builtin profile with this name, or `nil` when no
    ///   builtin profile has this name.
    public static func named(_ name: String) -> ProfileDefinition? {
        builtin.first { $0.name == name }
    }

    /// The name and the description of each builtin profile, in the order
    /// of ``ModelChoices/generation``.
    private static let summaries: [(name: String, description: String)] = [
        (defaultName, "The largest model, with a drafter for faster generation, for a Mac with much memory."),
        ("medium", "A medium model that uses less memory than the large profile, with good quality."),
        ("small", "A small model for a Mac with less memory."),
        ("tiny", "The smallest model, for a Mac with the least memory."),
    ]

    /// Makes a builtin profile that uses one model for generation.
    ///
    /// - Parameters:
    ///   - name: The name of the profile.
    ///   - description: The description of the profile, in one sentence.
    ///   - model: The model of the `standard` and `flash` slots.
    /// - Returns: The profile.
    private static func makeProfile(name: String, description: String, model: ModelRef) -> ProfileDefinition {
        ProfileDefinition(
            name: name,
            description: description,
            standard: [model],
            flash: [model],
            embedding: Array(ModelChoices.embedding.prefix(1)),
            decision: ProfileDefinition.defaultDecisionCandidates,
            context: nil,
            decisionContext: ProfileDefinition.defaultDecisionContext
        )
    }
}
