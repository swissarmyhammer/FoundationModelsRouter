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
    /// type: the pool keys a model by its ref, this role and, for a model
    /// that loads at a fixed context, that context.
    public var poolRole: ModelRole {
        switch self {
        case .standard, .flash: .llm
        case .embedding: .embedding
        }
    }

    /// The key that the router asks the Extras model pool for, for `ref` in
    /// this slot. A generation slot asks at `context`, the context of the
    /// resolve, so a loader that loads at a fixed context (GGUF) loads at it.
    /// The loader of the pool drops the context when it ignores it
    /// (``ModelLoader/poolKey(for:)``). The embedding slot asks with no
    /// context.
    ///
    /// - Parameters:
    ///   - ref: The model.
    ///   - context: The context that the resolve decided for this slot.
    /// - Returns: The key of the request.
    func poolKey(of ref: ModelRef, context: Int) -> ModelPoolKey {
        switch poolRole {
        case .llm: ModelPoolKey(ref: ref, role: .llm, contextSize: context)
        case .embedding: ModelPoolKey(ref: ref, role: .embedding)
        }
    }
}
