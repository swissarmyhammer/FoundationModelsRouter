/// The shared UTF-8 byte-budget prefix walk.
///
/// The budget is stated in the UTF-8 bytes ``Compactor/estimatedTokenCount(of:)``
/// divides, so every caller spends the same unit.
enum UTF8Budget {
    /// The longest prefix of `text` whose UTF-8 encoding is at most `maxBytes`
    /// bytes. The prefix ends on a `Character` boundary, so it never splits a
    /// scalar or a grapheme cluster.
    ///
    /// - Parameters:
    ///   - text: The text to take a prefix of.
    ///   - maxBytes: The UTF-8 bytes the returned prefix may occupy.
    /// - Returns: The prefix; empty when `maxBytes` is zero or negative.
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
