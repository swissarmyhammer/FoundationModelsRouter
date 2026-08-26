/// The role a model plays within a profile.
///
/// The raw `String` value is the slot's stable wire form (`"standard"`,
/// `"flash"`, `"embedding"`). It names a slot in a recorded ``TranscriptEvent``.
public enum ModelSlot: String, Sendable, Hashable, Codable {
    /// The primary, higher-quality generation model.
    case standard
    /// A smaller, faster generation model for latency-sensitive work.
    case flash
    /// A model that produces vector embeddings rather than text.
    case embedding
}
