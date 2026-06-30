/// An authored profile: the named set of candidate models the router resolves
/// from, plus the working context budget those models run under.
///
/// Each slot (`standard`, `flash`, `embedding`) lists candidate ``ModelRef``s in
/// preference order; resolution picks the first that fits the request and
/// residency constraints. `context` is the working context size in tokens — it
/// scales the KV-cache footprint and determines whether a candidate fits.
///
/// The type is pure value semantics — no dependency on MLX — and is `Sendable`.
public struct ProfileDefinition: Sendable {
    /// The default working context size in tokens (8K) when none is specified.
    public static let defaultContext = 8192

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

    /// The working context size in tokens. Scales the KV-cache footprint and
    /// determines candidate fit. Defaults to ``defaultContext`` (8192).
    public var context: Int

    /// Creates a profile definition.
    ///
    /// - Parameters:
    ///   - name: The profile's unique, human-meaningful name.
    ///   - description: A short description of the profile's intent.
    ///   - standard: Candidate models for the `standard` slot.
    ///   - flash: Candidate models for the `flash` slot.
    ///   - embedding: Candidate models for the `embedding` slot.
    ///   - context: The working context size in tokens; defaults to 8192.
    public init(
        name: String,
        description: String,
        standard: [ModelRef],
        flash: [ModelRef],
        embedding: [ModelRef],
        context: Int = ProfileDefinition.defaultContext
    ) {
        self.name = name
        self.description = description
        self.standard = standard
        self.flash = flash
        self.embedding = embedding
        self.context = context
    }

    /// The per-slot candidate lists keyed by ``ModelSlot``, exposing the slot
    /// candidates as data so callers resolve a slot's candidates by lookup
    /// rather than by branching over the slot. The mapping is total — it
    /// contains an entry for every ``ModelSlot`` case — and each list preserves
    /// the author's preference order.
    public var candidatesBySlot: [ModelSlot: [ModelRef]] {
        [.standard: standard, .flash: flash, .embedding: embedding]
    }
}
