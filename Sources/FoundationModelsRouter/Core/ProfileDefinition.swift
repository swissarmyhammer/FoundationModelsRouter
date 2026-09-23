/// An authored profile: the named set of candidate models the router resolves from, plus the working context budget those models run under.
///
/// Each slot (`standard`, `flash`, `embedding`) lists candidate ``ModelRef``s in
/// preference order; resolution picks the first that fits the request and
/// residency constraints. `context` is the working context size in tokens — it
/// scales the KV-cache footprint and determines whether a candidate fits.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`
/// and `Codable`. `context`'s `Codable` shape is back-compatible by
/// construction (an ordinary `Optional`'s synthesized coding): JSON that omits
/// the key decodes to `nil`, and legacy JSON carrying a number decodes to that
/// number unchanged.
public struct ProfileDefinition: Sendable, Codable {
    /// The profile's unique, human-meaningful name.
    public var name: String

    /// A short description of the profile's intent.
    public var description: String

    /// Candidate models for the `standard` slot, in preference order.
    public var standard: [ModelRef]

    /// Candidate models for the `flash` slot, in preference order.
    public var flash: [ModelRef]

    /// Candidate models for the `embedding` slot, in preference order.
    public var embedding: [ModelRef]

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
    ///   - context: The working context size in tokens, as an override.
    ///     Omit it, or pass `nil`, to derive the context from the model at
    ///     resolve time.
    public init(
        name: String,
        description: String,
        standard: [ModelRef],
        flash: [ModelRef],
        embedding: [ModelRef],
        context: Int? = nil
    ) {
        self.name = name
        self.description = description
        self.standard = standard
        self.flash = flash
        self.embedding = embedding
        self.context = context
    }

    /// The per-slot candidate lists keyed by ``ModelSlot``, exposing the slot candidates as data so callers resolve a slot's candidates by lookup rather than by branching over the slot.
    ///
    /// The mapping is total — it contains an entry for every ``ModelSlot``
    /// case — and each list preserves the author's preference order.
    var candidatesBySlot: [ModelSlot: [ModelRef]] {
        [.standard: standard, .flash: flash, .embedding: embedding]
    }
}
