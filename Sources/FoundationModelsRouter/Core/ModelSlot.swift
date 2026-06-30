/// The role a model plays within a profile.
///
/// A profile supplies candidate models for each slot; resolution picks the
/// model that fits the current request and residency constraints.
///
/// - `standard`: the primary, higher-quality generation model.
/// - `flash`: a smaller, faster generation model for latency-sensitive work.
/// - `embedding`: a model that produces vector embeddings rather than text.
///
/// The raw `String` value is the slot's stable wire form (`"standard"`,
/// `"flash"`, `"embedding"`), so it `Codable`-encodes to a single clean string —
/// matching how the rest of the core types serialize — and can name a slot in a
/// recorded ``TranscriptEvent``.
public enum ModelSlot: String, Sendable, Hashable, Codable {
    /// The primary, higher-quality generation model.
    case standard
    /// A smaller, faster generation model for latency-sensitive work.
    case flash
    /// A model that produces vector embeddings rather than text.
    case embedding
}
