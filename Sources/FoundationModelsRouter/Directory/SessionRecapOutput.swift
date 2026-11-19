import Foundation

/// The recap of a session from the output of the recap call (D206).
///
/// The recap is one line: the call removes each double quote, puts one space
/// in place of each run of white space and line breaks, and removes the
/// single quotes at the two ends. A line longer than ``characterLimit`` is
/// cut at the end of the last whole word that fits. An output with no words
/// gives no recap, so the record keeps its previous recap.
enum SessionRecapOutput {
    /// The most characters of a recap.
    static let characterLimit = 200

    /// The double quotes that the recap does not keep, at any place.
    private static let doubleQuotes: Set<Character> = ["\"", "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}"]

    /// The single quotes that the recap does not keep at its two ends. A
    /// single quote inside the line is an apostrophe, and it stays.
    private static let singleQuotes = CharacterSet(charactersIn: "'\u{2018}\u{2019}")

    /// The character that separates two words of the recap.
    private static let space: Character = " "

    /// The recap that `output` gives.
    ///
    /// - Parameter output: The output of the recap call.
    /// - Returns: The recap, or `nil` when the output has no words.
    static func recap(from output: String) -> String? {
        let words = output.filter { !doubleQuotes.contains($0) }.split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: String(space)).trimmingCharacters(in: singleQuotes)
        guard !line.isEmpty else { return nil }
        return cutAtWord(line)
    }

    /// `line`, or the part of `line` up to the end of the last whole word in
    /// its first ``characterLimit`` characters. A first word longer than the
    /// limit is cut at the limit.
    ///
    /// - Parameter line: One line with one space between two words.
    /// - Returns: At most ``characterLimit`` characters.
    private static func cutAtWord(_ line: String) -> String {
        guard line.count > characterLimit else { return line }
        // One character more than the limit: when it is a space, the cut at
        // the limit falls at the end of a word.
        let head = line.prefix(characterLimit + 1)
        guard let lastSpace = head.lastIndex(of: space) else { return String(line.prefix(characterLimit)) }
        return String(head[..<lastSpace])
    }
}
