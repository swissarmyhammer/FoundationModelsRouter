/// The text that an embedding model needs in front of each input, by kind of
/// input.
///
/// Some embedding models are trained with a fixed prefix on each text. A
/// prefix for a query differs from a prefix for a document. The model gives
/// bad vectors when the prefix is missing. The loader of the model adds no
/// prefix, so the router adds it. ``RoutedModel/embed(queries:)`` and
/// ``RoutedModel/embed(documents:)`` read the prefix from ``table``.
///
/// ``table`` has one entry for each model repo that needs a prefix. The key is
/// the repo of the ``ModelRef``, with no revision. A model with no entry gets
/// no prefix, and its texts reach the container as the caller gave them.
///
/// To support a new model, add one entry to ``table``. Take the two strings
/// from the model card of that model.
///
/// Some models also read only a fixed number of tokens and cut a longer text
/// with no error. The router has no token counter for an embedding model, so
/// it cannot tell a caller that a text is too long. See
/// `docs/ane-embedding.md` for the limit of each model.
struct EmbeddingPrefix: Equatable, Sendable {
    /// The text that goes in front of a query.
    let query: String

    /// The text that goes in front of a document.
    let document: String

    /// The prefixes by model repo.
    ///
    /// `erjigit17/embeddinggemma-300m-ane-coreml` needs both prefixes. It
    /// reads 128 tokens, and the prefix uses some of them.
    static let table: [String: EmbeddingPrefix] = [
        "erjigit17/embeddinggemma-300m-ane-coreml": EmbeddingPrefix(
            query: "task: search result | query: ",
            document: "title: none | text: "
        )
    ]

    /// Finds the prefixes for a model.
    ///
    /// - Parameter model: The model that embeds the texts.
    /// - Returns: The prefixes of the model, or `nil` when the model needs
    ///   none.
    static func prefix(for model: ModelRef) -> EmbeddingPrefix? {
        table[model.repo]
    }
}
