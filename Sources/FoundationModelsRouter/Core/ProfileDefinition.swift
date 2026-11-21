/// An authored profile: the named set of candidate models the router resolves from, plus the working context budget those models run under.
///
/// Each slot (`standard`, `flash`, `embedding`, `decision`) lists candidate
/// ``ModelRef``s in preference order; resolution picks the first that fits the
/// request and residency constraints. Every slot must resolve: when no
/// candidate of a slot fits, the decision slot included, the resolve fails.
/// `context` is the working context size in tokens — it
/// scales the KV-cache footprint and determines whether a candidate fits.
///
/// The `standard` and `flash` slots can name the same model. The resolve then
/// loads the model once, and the `flash` slot costs only one session of KV
/// cache at the context.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`
/// and `Codable`. `context`'s `Codable` shape is back-compatible by
/// construction (an ordinary `Optional`'s synthesized coding): JSON that omits
/// the key decodes to `nil`, and legacy JSON carrying a number decodes to that
/// number unchanged.
///
/// Only the `name` key is required. Each other key has a default here, in
/// this type, and a profile never takes a missing key from another profile:
///
/// - `description`: ``defaultDescription``.
/// - `standard`: ``defaultStandardCandidates``.
/// - `flash`: the `standard` list of the same profile.
/// - `embedding`: ``defaultEmbeddingCandidates``.
/// - `decision`: ``defaultDecisionCandidates``.
/// - `context`: `nil`.
/// - `decisionContext`: ``defaultDecisionContext``.
/// - `kvBits`: an fp16 cache.
public struct ProfileDefinition: Sendable, Codable {
    /// The profile's unique, human-meaningful name.
    public var name: String

    /// A short description of the profile's intent.
    ///
    /// The default is ``defaultDescription``.
    public var description: String

    /// The description that a profile gets when it names none: an empty
    /// text.
    public static let defaultDescription = ""

    /// Candidate models for the `standard` slot, in preference order.
    ///
    /// The default is ``defaultStandardCandidates``.
    public var standard: [ModelRef]

    /// The `standard` candidates that a profile gets when it names none: the
    /// `mlx-community/Qwen3.5-9B-4bit` model, with its MTP head
    /// `mlx-community/Qwen3.5-9B-MTP-4bit` as the drafter.
    ///
    /// A host needs 16 GB of memory or more, and this model fits in that
    /// minimum. Thus the default resolves on each Mac that a host supports.
    public static let defaultStandardCandidates: [ModelRef] = [
        ModelRef(repo: "mlx-community/Qwen3.5-9B-4bit", drafter: "mlx-community/Qwen3.5-9B-MTP-4bit")
    ]

    /// Candidate models for the `flash` slot, in preference order.
    ///
    /// A candidate can be the model of the `standard` slot. The resolve then
    /// loads that model once, and the `flash` slot costs only one session of
    /// KV cache at the context. The default is the ``standard`` list of the
    /// same profile.
    public var flash: [ModelRef]

    /// Candidate models for the `embedding` slot, in preference order.
    ///
    /// The default is ``defaultEmbeddingCandidates``.
    public var embedding: [ModelRef]

    /// The `embedding` candidates that a profile gets when it names none: the
    /// `erjigit17/embeddinggemma-300m-ane-coreml` model, a Core ML model for
    /// the Neural Engine.
    public static let defaultEmbeddingCandidates: [ModelRef] = [
        "erjigit17/embeddinggemma-300m-ane-coreml"
    ]

    /// The candidate models of the decision slot, in preference order.
    ///
    /// The slot is required: when no candidate fits, or the list is empty,
    /// the resolve fails. The slot never uses the model of another slot in
    /// place of its own candidates. A candidate can name the model of the
    /// `standard` or `flash` slot, and then costs no more memory.
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

    /// The context of the decision slot, in tokens: the slot sizes, keys and
    /// loads its model at this context, and not at ``context``.
    ///
    /// A decision state is small, and a GGUF decision model allocates its
    /// whole KV cache at load, so the shared window would take memory from
    /// the `standard` window for nothing. The host builds each
    /// `DecisionState`, so the bound on its size is the host's to choose. The
    /// default is ``defaultDecisionContext``.
    public var decisionContext: Int

    /// The context of the decision slot that a profile gets when it names
    /// none: 16,384 tokens.
    public static let defaultDecisionContext = 16_384

    /// How the language models of the profile store their KV cache, or
    /// `nil` for fp16 (task ^vp19r4r).
    ///
    /// The router sizes each session KV cache of the `standard`, `flash` and
    /// `decision` slots with it, and loads each of their models with it, under
    /// a pool key that carries it. Thus a decision candidate that names the
    /// `standard` model still shares it, and two profiles that name one model
    /// with another setting never share a resident model. Its key is
    /// `kvBits`, the bits of each element: 8 or 4, or no key for fp16.
    public var kvCacheQuantization: KVCacheQuantization?

    /// Creates a profile definition.
    ///
    /// - Parameters:
    ///   - name: The profile's unique, human-meaningful name. It is the
    ///     only parameter with no default.
    ///   - description: A short description of the profile's intent. Omit it
    ///     to use ``defaultDescription``.
    ///   - standard: Candidate models for the `standard` slot. Omit it to use
    ///     ``defaultStandardCandidates``.
    ///   - flash: Candidate models for the `flash` slot. Omit it, or pass
    ///     `nil`, to use the `standard` list.
    ///   - embedding: Candidate models for the `embedding` slot. Omit it to
    ///     use ``defaultEmbeddingCandidates``.
    ///   - decision: Candidate models for the decision slot. Omit it to use
    ///     ``defaultDecisionCandidates``.
    ///   - context: The working context size in tokens, as an override.
    ///     Omit it, or pass `nil`, to derive the context from the model at
    ///     resolve time.
    ///   - decisionContext: The context of the decision slot, in tokens.
    ///     Omit it to use ``defaultDecisionContext``.
    ///   - kvCacheQuantization: How the language models store their KV
    ///     cache. Omit it, or pass `nil`, for fp16.
    public init(
        name: String,
        description: String = ProfileDefinition.defaultDescription,
        standard: [ModelRef] = ProfileDefinition.defaultStandardCandidates,
        flash: [ModelRef]? = nil,
        embedding: [ModelRef] = ProfileDefinition.defaultEmbeddingCandidates,
        decision: [ModelRef] = ProfileDefinition.defaultDecisionCandidates,
        context: Int? = nil,
        decisionContext: Int = ProfileDefinition.defaultDecisionContext,
        kvCacheQuantization: KVCacheQuantization? = nil
    ) {
        self.name = name
        self.description = description
        self.standard = standard
        self.flash = flash ?? standard
        self.embedding = embedding
        self.decision = decision
        self.context = context
        self.decisionContext = decisionContext
        self.kvCacheQuantization = kvCacheQuantization
    }

    /// The keys of a profile. ``kvCacheQuantization`` has the key `kvBits`.
    private enum CodingKeys: String, CodingKey {
        case name, description, standard, flash, embedding, decision, context, decisionContext
        case kvCacheQuantization = "kvBits"
    }

    /// Creates a profile definition from a decoder.
    ///
    /// Only the `name` key is required. A missing `description` key gives
    /// ``defaultDescription``. A missing `standard` key gives
    /// ``defaultStandardCandidates``. A missing `flash` key gives the
    /// `standard` list of this profile, decoded or default. A missing
    /// `embedding` key gives ``defaultEmbeddingCandidates``. A missing
    /// `decision` key gives ``defaultDecisionCandidates``. A missing
    /// `context` key gives `nil`. A missing `decisionContext` key gives
    /// ``defaultDecisionContext``. A missing `kvBits` key gives an fp16 cache.
    ///
    /// - Parameter decoder: The decoder to read the profile from.
    /// - Throws: `DecodingError` when the `name` key is missing, when a
    ///   value has the wrong type, or when `kvBits` is not 8 or 4.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description)
                ?? Self.defaultDescription,
            standard: try container.decodeIfPresent([ModelRef].self, forKey: .standard)
                ?? Self.defaultStandardCandidates,
            flash: try container.decodeIfPresent([ModelRef].self, forKey: .flash),
            embedding: try container.decodeIfPresent([ModelRef].self, forKey: .embedding)
                ?? Self.defaultEmbeddingCandidates,
            decision: try container.decodeIfPresent([ModelRef].self, forKey: .decision)
                ?? Self.defaultDecisionCandidates,
            context: try container.decodeIfPresent(Int.self, forKey: .context),
            decisionContext: try container.decodeIfPresent(Int.self, forKey: .decisionContext)
                ?? Self.defaultDecisionContext,
            kvCacheQuantization: try Self.decodeKVBits(from: container)
        )
    }

    /// Encodes the profile: `kvBits` as the bits of each element, with no
    /// key for fp16, and no `context` key when the context is `nil`.
    ///
    /// - Parameter encoder: The encoder to write the profile to.
    /// - Throws: What the encoder throws.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(description, forKey: .description)
        try container.encode(standard, forKey: .standard)
        try container.encode(flash, forKey: .flash)
        try container.encode(embedding, forKey: .embedding)
        try container.encode(decision, forKey: .decision)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encode(decisionContext, forKey: .decisionContext)
        try container.encodeIfPresent(kvCacheQuantization?.bits, forKey: .kvCacheQuantization)
    }

    /// The quantization that the `kvBits` key of `container` names.
    ///
    /// - Parameter container: The keys of a profile.
    /// - Returns: The quantization, or `nil` when the key is absent.
    /// - Throws: `DecodingError` when the value is not the integer 8 or 4.
    private static func decodeKVBits(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> KVCacheQuantization? {
        guard let bits = try container.decodeIfPresent(Int.self, forKey: .kvCacheQuantization) else { return nil }
        guard let quantization = KVCacheQuantization(bits: bits) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kvCacheQuantization, in: container,
                debugDescription: "kvBits is \(bits); it must be 8 or 4, or absent for fp16")
        }
        return quantization
    }

    /// The per-slot candidate lists keyed by ``ModelSlot``, exposing the slot candidates as data so callers resolve a slot's candidates by lookup rather than by branching over the slot.
    ///
    /// The mapping is total — it contains an entry for every ``ModelSlot``
    /// case — and each list preserves the author's preference order.
    var candidatesBySlot: [ModelSlot: [ModelRef]] {
        [.standard: standard, .flash: flash, .embedding: embedding, .decision: decision]
    }
}
