/// The one UTF-8 byte-budget prefix walk this module has.
///
/// Two callers reach it, and they arrived at the same walk independently, which
/// is why it now stands here rather than twice:
///
/// - ``ToolOutputCapping/capped(text:toTokenLimit:)`` truncates a tool's output
///   to ``TokenBudget/toolOutputLimit`` tokens before the model reads it.
/// - ``Summarization/cut(_:toCharacters:)`` bounds a summarizer's answer to the
///   share of its own content that call may retain.
///
/// Both spend a budget stated in the UTF-8 bytes
/// ``Compactor/estimatedTokenCount(of:)`` divides, so both ask the same
/// question of the same unit, and an answer that drifted between them would be
/// a latent defect in whichever copy stopped being read.
///
/// It lives in `Core` rather than beside either caller because the two sit in
/// different areas of the module — `Session` and `Compaction` — and a string
/// operation is not a reason for one of those to depend on the other.
enum UTF8Budget {
    /// The longest prefix of `text` whose UTF-8 encoding is at most `maxBytes`
    /// bytes.
    ///
    /// Accumulated one `Character` (extended grapheme cluster) at a time rather
    /// than sliced at a byte offset, because a byte offset can land inside a
    /// multi-byte scalar or inside a grapheme cluster, and neither is a place a
    /// string can be split. So the result never ends mid-scalar and never
    /// splits an emoji, whatever the text's script.
    ///
    /// - Parameters:
    ///   - text: The text to take a prefix of.
    ///   - maxBytes: The UTF-8 bytes the returned prefix may occupy.
    /// - Returns: The longest `Character`-boundary prefix of `text` that fits
    ///   in `maxBytes` bytes; empty when `maxBytes` is zero or negative.
    static func prefix(of text: String, keepingAtMostBytes maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }

        var kept = ""
        var byteCount = 0
        for character in text {
            let characterByteCount = character.utf8.count
            guard byteCount + characterByteCount <= maxBytes else { break }
            kept.append(character)
            byteCount += characterByteCount
        }
        return kept
    }
}
