import Foundation
import MLXLMCommon
import Testing

@testable import FoundationModelsRouter

/// Exercises ``PinnedDateTokenizerLoader`` — no network, no GPU, no weights.
///
/// The loader exists because a chat template can read the clock. The Llama 3.2
/// template writes `Today Date: <today>` into every system header, and it takes
/// that date from `strftime_now`, which `swift-jinja` answers from `Date()`.
/// Greedy decoding pins the sampling; it does not pin the prompt. So identical
/// code folds a transcript differently on two calendar days.
///
/// The template reads its own `date_string` variable first, and only calls
/// `strftime_now` when nothing defines it. So a caller that states
/// `date_string` stops the clock reaching the prompt. These tests hold the
/// loader to stating it, and to leaving everything else the way it found it.
///
/// One name is not enough. Each model family names the variable itself, and
/// the Muse Glimmer family reads `current_date` where the Llama family reads
/// `date_string`. So these tests hold the loader to stating EVERY name it
/// claims, and to leaving each name a call states alone by itself.
@Suite("PinnedDateTokenizerLoader pins the chat template's date")
struct PinnedDateTokenizerLoaderTests {
    /// The date every test of this suite pins.
    ///
    /// Written the way the Llama 3.2 template writes it, so the value reads as
    /// the thing it replaces.
    private static let pinnedDate = "26 Jul 2024"

    /// One pinned template variable, beside a second the same render carries.
    ///
    /// The rule the loader holds is stated per NAME, so a test of it needs two
    /// names at once: the one the call states, and one the call leaves to the
    /// loader.
    struct NamePair: Sendable {
        /// The variable the call states a date for itself.
        let stated: String

        /// A variable the call leaves alone, which the loader pins.
        let other: String
    }

    /// Every pinned variable, each paired with another pinned variable.
    ///
    /// Both orders, so neither name is proved only as the one the call states
    /// nor only as the one the loader pins.
    private static let namePairs = [
        NamePair(
            stated: PinnedDateTokenizerLoader.dateStringTemplateKey,
            other: PinnedDateTokenizerLoader.currentDateTemplateKey),
        NamePair(
            stated: PinnedDateTokenizerLoader.currentDateTemplateKey,
            other: PinnedDateTokenizerLoader.dateStringTemplateKey),
    ]

    /// The directory the loader is asked to load from.
    ///
    /// ``EchoingTokenizerLoader`` reads no file, so any path serves.
    private static let unreadDirectory = URL(fileURLWithPath: "/nonexistent")

    // MARK: - The stub tokenizer

    /// A ``Tokenizer`` that renders the chat-template context it is handed,
    /// rather than a conversation.
    ///
    /// A decorator's whole job is what it passes DOWN, and a stub that answers
    /// with what it received is how a test reads that. ``encode(text:addSpecialTokens:)``
    /// and ``decode(tokenIds:skipSpecialTokens:)`` are true inverses here, so a
    /// test decodes the render with the tokenizer's own decoder.
    private struct EchoingTokenizer: Tokenizer {
        /// The token this tokenizer reports as every special token, so a test
        /// can prove a decorator forwards the properties rather than inventing
        /// them.
        static let specialToken = "<stub>"

        /// The ID ``convertTokenToId(_:)`` answers for every token.
        static let specialTokenID = 7

        /// Renders a chat-template context as one `key=value` line per entry,
        /// sorted by key so the render is the same on every run.
        ///
        /// - Parameters:
        ///   - additionalContext: the template variables the call supplied.
        ///   - addGenerationPrompt: whether the call asked for the
        ///     generation-priming region. Rendered as its own line, so a test
        ///     can tell the two overloads apart.
        /// - Returns: the rendered context.
        static func render(
            _ additionalContext: [String: any Sendable]?,
            addGenerationPrompt: Bool
        ) -> String {
            let entries = (additionalContext ?? [:])
                .map { "\($0.key)=\($0.value)" }
                .sorted()
            return (["addGenerationPrompt=\(addGenerationPrompt)"] + entries).joined(separator: "\n")
        }

        /// Reads text as its UTF-8 bytes.
        /// - Parameters:
        ///   - text: the text to tokenize.
        ///   - addSpecialTokens: ignored; this tokenizer defines no special
        ///     token it could add.
        /// - Returns: one token ID per UTF-8 byte.
        func encode(text: String, addSpecialTokens: Bool) -> [Int] {
            Array(text.utf8).map(Int.init)
        }

        /// Reads token IDs back as the text ``encode(text:addSpecialTokens:)``
        /// was given.
        /// - Parameters:
        ///   - tokenIds: the token IDs to decode.
        ///   - skipSpecialTokens: ignored; this tokenizer writes no special
        ///     token into a render.
        /// - Returns: the decoded text.
        func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
            String(decoding: tokenIds.compactMap { UInt8(exactly: $0) }, as: UTF8.self)
        }

        /// Answers ``specialTokenID`` for every token.
        /// - Parameter token: the token text.
        /// - Returns: ``specialTokenID``.
        func convertTokenToId(_ token: String) -> Int? { Self.specialTokenID }

        /// Answers ``specialToken`` for every ID.
        /// - Parameter id: the token ID.
        /// - Returns: ``specialToken``.
        func convertIdToToken(_ id: Int) -> String? { Self.specialToken }

        /// The stub's beginning-of-sequence token.
        var bosToken: String? { Self.specialToken }

        /// The stub's end-of-sequence token.
        var eosToken: String? { Self.specialToken }

        /// The stub's unknown token.
        var unknownToken: String? { Self.specialToken }

        /// Renders the context the call supplied.
        /// - Parameters:
        ///   - messages: ignored; this tokenizer renders the context, not the
        ///     conversation.
        ///   - tools: ignored, for the same reason.
        ///   - additionalContext: the template variables to render.
        /// - Returns: the render, as UTF-8 token IDs.
        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?
        ) throws -> [Int] {
            encode(
                text: Self.render(additionalContext, addGenerationPrompt: true),
                addSpecialTokens: false)
        }

        /// Renders the context the call supplied, with the generation-prompt
        /// flag it stated.
        ///
        /// Implemented rather than left to the protocol's `nil` default, so a
        /// test can prove a decorator forwards this overload instead of
        /// answering `nil` in its place.
        ///
        /// - Parameters:
        ///   - messages: ignored, as above.
        ///   - tools: ignored, as above.
        ///   - additionalContext: the template variables to render.
        ///   - addGenerationPrompt: whether the call asked for the
        ///     generation-priming region.
        /// - Returns: the render, as UTF-8 token IDs.
        func applyChatTemplate(
            messages: [[String: any Sendable]],
            tools: [[String: any Sendable]]?,
            additionalContext: [String: any Sendable]?,
            addGenerationPrompt: Bool
        ) throws -> [Int]? {
            encode(
                text: Self.render(additionalContext, addGenerationPrompt: addGenerationPrompt),
                addSpecialTokens: false)
        }
    }

    /// A ``TokenizerLoader`` that vends an ``EchoingTokenizer`` and reads no
    /// file.
    private struct EchoingTokenizerLoader: TokenizerLoader {
        /// Vends the stub.
        /// - Parameter directory: ignored; nothing is read from disk.
        /// - Returns: the stub tokenizer.
        func load(from directory: URL) async throws -> any Tokenizer {
            EchoingTokenizer()
        }
    }

    // MARK: - Helpers

    /// Loads a pinned-date tokenizer over ``EchoingTokenizerLoader``.
    ///
    /// - Returns: the decorated tokenizer.
    /// - Throws: whatever the load throws.
    private static func pinnedTokenizer() async throws -> any Tokenizer {
        let loader = PinnedDateTokenizerLoader(
            wrapping: EchoingTokenizerLoader(), dateString: pinnedDate)
        return try await loader.load(from: unreadDirectory)
    }

    // MARK: - The tests

    @Test("a call that states no template context is given the pinned date under every name")
    func pinsEveryDateNameWhenTheCallStatesNoContext() async throws {
        let tokenizer = try await Self.pinnedTokenizer()

        let rendered = tokenizer.decode(
            tokenIds: try tokenizer.applyChatTemplate(
                messages: [], tools: nil, additionalContext: nil))

        #expect(rendered.contains("date_string=\(Self.pinnedDate)"))
        #expect(rendered.contains("current_date=\(Self.pinnedDate)"))
    }

    @Test("the template variables the call states are kept beside the pinned date")
    func keepsTheContextTheCallStates() async throws {
        let tokenizer = try await Self.pinnedTokenizer()

        let rendered = tokenizer.decode(
            tokenIds: try tokenizer.applyChatTemplate(
                messages: [], tools: nil, additionalContext: ["thinking": false]))

        #expect(rendered.contains("date_string=\(Self.pinnedDate)"))
        #expect(rendered.contains("thinking=false"))
    }

    @Test(
        "a date the call states itself is left alone, and the other name is still pinned",
        arguments: Self.namePairs)
    func leavesADateTheCallStates(names: NamePair) async throws {
        let statedDate = "01 Jan 2000"
        let tokenizer = try await Self.pinnedTokenizer()

        let rendered = tokenizer.decode(
            tokenIds: try tokenizer.applyChatTemplate(
                messages: [], tools: nil, additionalContext: [names.stated: statedDate]))

        #expect(rendered.contains("\(names.stated)=\(statedDate)"))
        #expect(!rendered.contains("\(names.stated)=\(Self.pinnedDate)"))
        #expect(rendered.contains("\(names.other)=\(Self.pinnedDate)"))
    }

    @Test("the generation-prompt render carries every pinned name and the flag it was given")
    func pinsTheDateOnTheGenerationPromptRender() async throws {
        let tokenizer = try await Self.pinnedTokenizer()

        let tokenIds = try #require(
            try tokenizer.applyChatTemplate(
                messages: [], tools: nil, additionalContext: nil, addGenerationPrompt: false),
            "the decorator answered nil where the tokenizer it wraps renders")
        let rendered = tokenizer.decode(tokenIds: tokenIds)

        #expect(rendered.contains("date_string=\(Self.pinnedDate)"))
        #expect(rendered.contains("current_date=\(Self.pinnedDate)"))
        #expect(rendered.contains("addGenerationPrompt=false"))
    }

    @Test("every operation that is not a chat-template render reaches the wrapped tokenizer")
    func forwardsEveryOtherOperation() async throws {
        let tokenizer = try await Self.pinnedTokenizer()
        let text = "station archive"

        #expect(tokenizer.encode(text: text, addSpecialTokens: true) == Array(text.utf8).map(Int.init))
        #expect(tokenizer.decode(tokenIds: Array(text.utf8).map(Int.init)) == text)
        #expect(tokenizer.convertTokenToId(text) == EchoingTokenizer.specialTokenID)
        #expect(tokenizer.convertIdToToken(0) == EchoingTokenizer.specialToken)
        #expect(tokenizer.bosToken == EchoingTokenizer.specialToken)
        #expect(tokenizer.eosToken == EchoingTokenizer.specialToken)
        #expect(tokenizer.unknownToken == EchoingTokenizer.specialToken)
    }
}
