import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

/// The tag rule of ROUTER-2: a tag has 1 to 64
/// characters, each a letter, a digit, `-`, `_`, `:` or `.`; another tag
/// throws `SessionDirectoryError.invalidTag`.
@Suite struct SessionTagRuleTests {
    /// The tags the spec gives as examples.
    private static let exampleTags: Set<String> = ["reviewer", "travel", "scheduled", "kanban:task-42"]

    /// The longest tag the rule takes, in characters.
    private static let longestTagLength = 64

    /// The punctuation the rule takes, one tag for each.
    private static let allowedPunctuation = ["-", "_", ":", "."]

    /// Characters the rule refuses, one tag for each: a space, a slash, a
    /// hash, an at sign, a comma, an emoji and a digit that is not ASCII.
    private static let refusedCharacters = [" ", "/", "#", "@", ",", "🙂", "٣"]

    /// A valid tag with `character` in the middle.
    ///
    /// - Parameter character: The character to check.
    /// - Returns: The tag.
    private static func tag(around character: String) -> String {
        "a\(character)b"
    }

    /// Each example tag of the spec is valid.
    @Test func theExampleTagsAreValid() {
        #expect(throws: Never.self) { try SessionTagRule.validate(Self.exampleTags) }
    }

    /// No tags is a valid set: nothing to refuse.
    @Test func noTagsIsValid() {
        #expect(throws: Never.self) { try SessionTagRule.validate([]) }
    }

    /// A tag of the longest length is valid.
    @Test func aTagOfTheLongestLengthIsValid() {
        let longest = String(repeating: "a", count: Self.longestTagLength)

        #expect(throws: Never.self) { try SessionTagRule.validate([longest]) }
    }

    /// A tag one character longer than the limit throws `invalidTag`.
    @Test func aTagLongerThanTheLimitIsRefused() {
        let tooLong = String(repeating: "a", count: Self.longestTagLength + 1)

        #expect(throws: SessionDirectoryError.invalidTag(tooLong)) {
            try SessionTagRule.validate([tooLong])
        }
    }

    /// The empty tag throws `invalidTag`.
    @Test func theEmptyTagIsRefused() {
        #expect(throws: SessionDirectoryError.invalidTag("")) {
            try SessionTagRule.validate([""])
        }
    }

    /// Letters, in either case and beyond ASCII, and ASCII digits are valid.
    @Test func lettersAndDigitsAreValid() {
        #expect(throws: Never.self) {
            try SessionTagRule.validate(["abcxyz", "ABCXYZ", "café", "0123456789"])
        }
    }

    /// Each allowed punctuation character is valid in a tag.
    @Test(arguments: allowedPunctuation)
    func eachAllowedPunctuationIsValid(_ punctuation: String) {
        #expect(throws: Never.self) { try SessionTagRule.validate([Self.tag(around: punctuation)]) }
    }

    /// Each refused character makes its tag throw `invalidTag`.
    @Test(arguments: refusedCharacters)
    func eachRefusedCharacterIsRefused(_ character: String) {
        let refused = Self.tag(around: character)

        #expect(throws: SessionDirectoryError.invalidTag(refused)) {
            try SessionTagRule.validate([refused])
        }
    }

    /// Of several invalid tags, the first in name order is the one thrown,
    /// so the error is the same on every run.
    @Test func theFirstInvalidTagInNameOrderIsThrown() {
        #expect(throws: SessionDirectoryError.invalidTag("b c")) {
            try SessionTagRule.validate(["valid", "d e", "b c"])
        }
    }
}
