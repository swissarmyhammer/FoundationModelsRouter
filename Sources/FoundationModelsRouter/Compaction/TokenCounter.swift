import FoundationModels

/// Counts tokens the way one model counts them.
///
/// A session owns one counter, backed by the tokenizer of the loaded
/// container its model runs in (``LoadedLLMContainer/tokenCounter``). Every
/// token count the router makes before a model call comes from it: the size
/// of a transcript the compaction measures, the size of a summary, and the
/// size of a tool output the capping layer cuts. After a call, the exact
/// count is the engine's own `usage.input`. A scripted test backend supplies
/// a counter of its own, and states its rule in the test.
public protocol TokenCounter: Sendable {
    /// The token count of `text`.
    ///
    /// - Parameter text: The text to count.
    /// - Returns: The number of tokens the model reads `text` as.
    func count(_ text: String) -> Int

    /// The token count of `transcript` in the rendered form the model sees,
    /// the instructions included.
    ///
    /// - Parameter transcript: The transcript to count.
    /// - Returns: The number of tokens the model reads the rendered transcript as.
    /// - Throws: When the transcript cannot be rendered.
    func count(_ transcript: Transcript) throws -> Int

    /// The first `limit` tokens of `text`, decoded back to text.
    ///
    /// - Parameters:
    ///   - text: The text to cut.
    ///   - limit: The number of tokens to keep. Zero or below keeps nothing.
    /// - Returns: `text` unchanged when it holds at most `limit` tokens, else
    ///   the decoded prefix.
    func prefix(of text: String, tokens limit: Int) -> String
}
