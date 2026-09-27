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

extension ModelSlot {
    /// The role of the model of this slot in the Extras model pool. Both
    /// generation slots (``standard`` and ``flash``) map to ``ModelRole/llm``;
    /// ``embedding`` maps to ``ModelRole/embedding``. The slot stays a router
    /// type: the pool keys a model by its ref and this role only.
    public var poolRole: ModelRole {
        switch self {
        case .standard, .flash: .llm
        case .embedding: .embedding
        }
    }
}
