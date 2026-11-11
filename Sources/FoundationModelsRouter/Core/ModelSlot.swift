/// The role a model plays within a profile.
///
/// The raw `String` value is the slot's stable wire form (`"standard"`,
/// `"flash"`, `"embedding"`, `"decision"`). It names a slot in a recorded
/// ``TranscriptEvent``.
public enum ModelSlot: String, Sendable, Hashable, Codable {
    /// The primary, higher-quality generation model.
    case standard
    /// A smaller, faster generation model for latency-sensitive work.
    case flash
    /// A model that produces vector embeddings rather than text.
    case embedding
    /// A model that answers decision questions with probabilities (see
    /// ``RoutedDecider``). Each resolved profile has this slot. When no
    /// decision candidate fits, the slot uses the model of the ``flash`` slot.
    case decision
}

extension ModelSlot {
    /// The role of the model of this slot in the Extras model pool. The
    /// generation slots (``standard`` and ``flash``) and the ``decision`` slot
    /// map to ``ModelRole/llm``: a decision model is an LLM whose log
    /// probabilities give the answers. ``embedding`` maps to
    /// ``ModelRole/embedding``. The slot stays a router type: the pool keys a
    /// model by its ref, this role and, for a model that loads at a fixed
    /// context, that context.
    public var poolRole: ModelRole {
        switch self {
        case .standard, .flash, .decision: .llm
        case .embedding: .embedding
        }
    }

    /// The key that the router asks the Extras model pool for, for `ref` in
    /// this slot. A slot of the LLM role (generation and decision) asks at
    /// `context`, the context of the resolve, so a loader that loads at a
    /// fixed context (GGUF) loads at it. The loader of the pool drops the
    /// context when it ignores it (``ModelLoader/poolKey(for:)``). The
    /// embedding slot asks with no context.
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
