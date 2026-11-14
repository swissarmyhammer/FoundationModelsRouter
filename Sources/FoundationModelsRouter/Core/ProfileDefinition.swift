/// An authored profile: the named set of candidate models the router resolves from, plus the working context budget those models run under.
///
/// Each slot (`standard`, `flash`, `embedding`, `decision`) lists candidate
/// ``ModelRef``s in preference order; resolution picks the first that fits the
/// request and residency constraints. When no `decision` candidate fits, the
/// decision slot uses the `flash` model. `context` is the working context size in tokens — it
/// scales the KV-cache footprint and determines whether a candidate fits.
///
/// The `standard` and `flash` slots of one resolved profile never use the same
/// model. A synchronous tool call, for example the multitool `searchTools`,
/// runs a selection call on `flash` inside an open submission on `standard`.
/// Each model has one FIFO work queue, so one model in both slots would wait on
/// itself. Resolution therefore skips, in the `flash` list, the model that
/// `standard` chose, and takes the next `flash` candidate. A profile whose
/// `standard` and `flash` lists name only the same one model fails to resolve
/// before any model loads. Name at least one `flash` candidate that is not the
/// `standard` model.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`
/// and `Codable`. `context`'s `Codable` shape is back-compatible by
/// construction (an ordinary `Optional`'s synthesized coding): JSON that omits
/// the key decodes to `nil`, and legacy JSON carrying a number decodes to that
/// number unchanged. JSON that omits the `decision` key decodes to
/// ``defaultDecisionCandidates``.
public struct ProfileDefinition: Sendable, Codable {
    /// The profile's unique, human-meaningful name.
    public var name: String

    /// A short description of the profile's intent.
    public var description: String

    /// Candidate models for the `standard` slot, in preference order.
    public var standard: [ModelRef]

    /// Candidate models for the `flash` slot, in preference order.
    ///
    /// Resolution skips the model the `standard` slot chose, because the two
    /// generation slots never use the same model.
    public var flash: [ModelRef]

    /// Candidate models for the `embedding` slot, in preference order.
    public var embedding: [ModelRef]

    /// The candidate models of the decision slot, in preference order.
    ///
    /// When no candidate fits, the decision slot uses the `flash` model. An
    /// empty list is valid: the decision slot then always uses the `flash`
    /// model.
    public var decision: [ModelRef]

    /// The decision candidates that a profile gets when it names none: the
    /// `h2o-lightning-4b` model, quantized to `Q4_K_M`, in GGUF format, at a
    /// pinned revision.
    ///
    /// The GGUF file has the decision type `h2o-lightning`. llama.cpp
    /// supports this type, thus the decision slot takes the native decision
    /// path: the decision code of llama.cpp makes the prompt and reads the
    /// answer.
    public static let defaultDecisionCandidates: [ModelRef] = [
        "h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b7a8c2d84426d0d143ca187f65d235934b"
    ]

    /// The working context size in tokens, or `nil` to derive it at resolve time from each candidate's native max context (``RepoMetadata/nativeMaxContext``) instead of a caller-supplied figure.
    ///
    /// Scales the KV-cache footprint and determines candidate fit once
    /// resolved to a concrete value. It is `nil` when the initializer's
    /// `context` parameter is omitted, so the model's own window is the
    /// default. A number is an override, for example to make a test compact
    /// early.
    public var context: Int?

    /// Creates a profile definition.
    ///
    /// - Parameters:
    ///   - name: The profile's unique, human-meaningful name.
    ///   - description: A short description of the profile's intent.
    ///   - standard: Candidate models for the `standard` slot.
    ///   - flash: Candidate models for the `flash` slot.
    ///   - embedding: Candidate models for the `embedding` slot.
    ///   - decision: Candidate models for the decision slot. Omit it to use
    ///     ``defaultDecisionCandidates``.
    ///   - context: The working context size in tokens, as an override.
    ///     Omit it, or pass `nil`, to derive the context from the model at
    ///     resolve time.
    public init(
        name: String,
        description: String,
        standard: [ModelRef],
        flash: [ModelRef],
        embedding: [ModelRef],
        decision: [ModelRef] = ProfileDefinition.defaultDecisionCandidates,
        context: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.standard = standard
        self.flash = flash
        self.embedding = embedding
        self.decision = decision
        self.context = context
    }

    /// Creates a profile definition from a decoder.
    ///
    /// A missing `decision` key gives ``defaultDecisionCandidates``. A missing
    /// `context` key gives `nil`.
    ///
    /// - Parameter decoder: The decoder to read the profile from.
    /// - Throws: `DecodingError` when a required key is missing, or when a
    ///   value has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decode(String.self, forKey: .description),
            standard: try container.decode([ModelRef].self, forKey: .standard),
            flash: try container.decode([ModelRef].self, forKey: .flash),
            embedding: try container.decode([ModelRef].self, forKey: .embedding),
            decision: try container.decodeIfPresent([ModelRef].self, forKey: .decision)
                ?? Self.defaultDecisionCandidates,
            context: try container.decodeIfPresent(Int.self, forKey: .context)
        )
    }

    /// The per-slot candidate lists keyed by ``ModelSlot``, exposing the slot candidates as data so callers resolve a slot's candidates by lookup rather than by branching over the slot.
    ///
    /// The mapping is total — it contains an entry for every ``ModelSlot``
    /// case — and each list preserves the author's preference order.
    var candidatesBySlot: [ModelSlot: [ModelRef]] {
        [.standard: standard, .flash: flash, .embedding: embedding, .decision: decision]
    }

    /// The one model that both the `standard` list and the `flash` list name
    /// alone, or `nil`.
    ///
    /// Such a profile cannot resolve, because the `standard` and `flash` slots
    /// never use the same model: when `standard` takes that model, `flash` has
    /// no other candidate. The router checks this before it sizes or loads a
    /// model, and throws ``SameGenerationModelFailure``.
    var sharedGenerationModel: ModelRef? {
        let generationModels = Set(standard + flash)
        guard generationModels.count == 1, !standard.isEmpty, !flash.isEmpty else { return nil }
        return generationModels.first
    }
}
