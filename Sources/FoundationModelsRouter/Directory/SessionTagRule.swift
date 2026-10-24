import FoundationModelsExtras

/// The tag rule of ROUTER-2: a tag has 1 to 64 characters, each a letter, an
/// ASCII digit, `-`, `_`, `:` or `.`. Examples: `reviewer`, `travel`,
/// `scheduled`, `kanban:task-42`.
///
/// ``RouterSessionDirectory`` checks every tag of a call against it before it
/// changes a record, so a call with one invalid tag writes nothing. The rule
/// is the one the Extras in-memory directory keeps: a letter is any
/// `Character` that `isLetter`, and a digit is an ASCII digit.
enum SessionTagRule {
    /// The most characters a tag has.
    static let lengthLimit = 64

    /// The punctuation a tag may hold beside its letters and digits.
    static let punctuation: Set<Character> = ["-", "_", ":", "."]

    /// Checks each tag of `tags` against the rule.
    ///
    /// - Parameter tags: The tags to check.
    /// - Throws: `SessionDirectoryError.invalidTag` with the first tag
    ///   outside the rule, in name order, so the error is the same for one
    ///   set on every call.
    static func validate(_ tags: Set<String>) throws {
        for tag in tags.sorted() where !isValid(tag) {
            throw SessionDirectoryError.invalidTag(tag)
        }
    }

    /// Tells whether `tag` follows the rule.
    ///
    /// - Parameter tag: The tag to check.
    /// - Returns: `true` for 1 to ``lengthLimit`` letters, ASCII digits and
    ///   ``punctuation``.
    private static func isValid(_ tag: String) -> Bool {
        (1...lengthLimit).contains(tag.count) && tag.allSatisfy(isAllowed)
    }

    /// Tells whether a tag may hold `character`.
    ///
    /// - Parameter character: One character of a tag.
    /// - Returns: `true` for a letter, an ASCII digit or ``punctuation``.
    private static func isAllowed(_ character: Character) -> Bool {
        character.isLetter || (character.isASCII && character.isNumber) || punctuation.contains(character)
    }
}
