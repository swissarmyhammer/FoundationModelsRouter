import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The MTP outcome of a generation call: the MLX executor of
/// `MLXFoundationModels` sends it as metadata on the response entry of a call
/// whose model speculates, and the session carries it on
/// ``GenerationCallUsage/speculativeDecoding``, so a bench run can prove that
/// MTP ran.
@Suite("Speculative decoding outcome: the MTP metadata of a generation call")
struct SpeculativeDecodingOutcomeTests {
    /// A prompt entry with `text`.
    ///
    /// - Parameter text: The prompt text.
    /// - Returns: The transcript entry.
    private static func prompt(_ text: String) -> Transcript.Entry {
        .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// A response entry with `text`, `id` and the given metadata.
    ///
    /// - Parameters:
    ///   - id: The id of the entry.
    ///   - text: The response text.
    ///   - metadata: The metadata the executor sent on the entry.
    /// - Returns: The transcript entry.
    private static func response(
        id: String, _ text: String = "done", metadata: [String: any ConvertibleToGeneratedContent] = [:]
    ) -> Transcript.Entry {
        .response(
            Transcript.Response(
                id: id, metadata: metadata, segments: [.text(Transcript.TextSegment(content: text))]))
    }

    /// The metadata of a call that drafted with MTP.
    private static var speculatedMetadata: [String: any ConvertibleToGeneratedContent] {
        ["speculativeDecoding": true, "acceptedDraftTokenCount": 30, "draftedTokenCount": 40]
    }

    /// The metadata of a call that fell back to plain decode.
    private static var fallbackMetadata: [String: any ConvertibleToGeneratedContent] {
        [
            "speculativeDecoding": false, "speculativeDecodingFallbackReason": "incompatibleDrafter",
            "acceptedDraftTokenCount": 0, "draftedTokenCount": 0,
        ]
    }

    @Test("a response that drafted with MTP gives its accepted and drafted counts")
    func speculatedResponse() throws {
        let entries = [Self.prompt("fix"), Self.response(id: "r1", metadata: Self.speculatedMetadata)]

        let found = try #require(SpeculativeDecodingOutcome.newest(in: entries, after: nil))

        #expect(found.entryID == "r1")
        #expect(
            found.outcome
                == SpeculativeDecodingOutcome(
                    speculated: true, fallbackReason: nil, acceptedDraftTokenCount: 30, draftedTokenCount: 40))
        #expect(found.outcome.acceptanceRate == 0.75)
    }

    @Test("a response that fell back to plain decode gives the reason")
    func fallbackResponse() throws {
        let entries = [Self.response(id: "r1", metadata: Self.fallbackMetadata)]

        let found = try #require(SpeculativeDecodingOutcome.newest(in: entries, after: nil))

        #expect(found.outcome.speculated == false)
        #expect(found.outcome.fallbackReason == "incompatibleDrafter")
        #expect(found.outcome.acceptanceRate == nil)
    }

    @Test("a response with no MTP metadata gives no outcome")
    func plainResponse() {
        let entries = [Self.response(id: "r1", metadata: ["incompleteOutput": false])]

        #expect(SpeculativeDecodingOutcome.newest(in: entries, after: nil) == nil)
    }

    @Test("the newest response with MTP metadata decides")
    func newestResponseDecides() throws {
        let entries = [
            Self.response(id: "r1", metadata: Self.fallbackMetadata),
            Self.response(id: "r2", metadata: Self.speculatedMetadata),
        ]

        let found = try #require(SpeculativeDecodingOutcome.newest(in: entries, after: nil))

        #expect(found.entryID == "r2")
    }

    @Test("a response that an earlier call already gave is not given again")
    func attributedResponseIsNotRepeated() {
        let entries = [Self.response(id: "r1", metadata: Self.speculatedMetadata), Self.prompt("next")]

        #expect(SpeculativeDecodingOutcome.newest(in: entries, after: "r1") == nil)
    }

    @Test("the journal line of a call names its MTP outcome")
    func usageDescriptionNamesTheOutcome() {
        let speculated = GenerationCallUsage(
            tokensIn: 10, tokensOut: 40, finishReason: .completed, entryKind: .text, contextFill: 0.1,
            speculativeDecoding: SpeculativeDecodingOutcome(
                speculated: true, fallbackReason: nil, acceptedDraftTokenCount: 30, draftedTokenCount: 40))
        let fellBack = GenerationCallUsage(
            tokensIn: 10, tokensOut: 40, finishReason: .completed, entryKind: .text, contextFill: 0.1,
            speculativeDecoding: SpeculativeDecodingOutcome(
                speculated: false, fallbackReason: "memoryBudgetExceeded", acceptedDraftTokenCount: 0,
                draftedTokenCount: 0))
        let plain = GenerationCallUsage(
            tokensIn: 10, tokensOut: 40, finishReason: .completed, entryKind: .text, contextFill: 0.1)

        #expect(speculated.description.hasSuffix(", MTP accepted 30 of 40 drafted tokens"))
        #expect(fellBack.description.hasSuffix(", MTP fell back to plain decode: memoryBudgetExceeded"))
        #expect(!plain.description.contains("MTP"))
    }
}
