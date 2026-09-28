import Testing

@testable import FoundationModelsRouter

/// Exercises ``PaddedTokenBatch``, the right-padded token batch and its
/// key-padding mask that `LiveEmbeddingContainer.embed(texts:in:)` gives to
/// the model and to the pooling (task ^nmmnn7k). No model and no GPU: the
/// batch is plain Swift arrays.
@Suite("PaddedTokenBatch padding mask")
struct PaddedTokenBatchTests {
    /// The token id a row is padded with. The embed path pads with the EOS id
    /// of the tokenizer, so the rows below end with this same id.
    private static let padToken = 2

    @Test("rows of 3 and 5 tokens pad to 5, and the mask marks each real token 1 and each pad 0")
    func maskMarksRealTokensAndPads() {
        let batch = PaddedTokenBatch(rows: [[10, 11, 12], [20, 21, 22, 23, 24]], padToken: Self.padToken)

        #expect(batch.width == 5)
        #expect(batch.tokens == [[10, 11, 12, 2, 2], [20, 21, 22, 23, 24]])
        #expect(batch.mask == [[1, 1, 1, 0, 0], [1, 1, 1, 1, 1]])
    }

    @Test("a real token that equals the pad id stays 1 in the mask")
    func realEOSTokenStaysInTheMask() {
        // Each row ends with the EOS id that the tokenizer adds, and the pad
        // is that same id. A mask built from the token values (`!= padToken`)
        // drops the real EOS; a mask built from the count of each row keeps it.
        let batch = PaddedTokenBatch(rows: [[10, 11, 2], [20, 21, 22, 23, 2]], padToken: Self.padToken)

        #expect(batch.tokens == [[10, 11, 2, 2, 2], [20, 21, 22, 23, 2]])
        #expect(batch.mask == [[1, 1, 1, 0, 0], [1, 1, 1, 1, 1]])
    }

    @Test("a batch of empty rows is one position wide, and that position is a pad")
    func emptyRowsPadToOnePosition() {
        let batch = PaddedTokenBatch(rows: [[]], padToken: Self.padToken)

        #expect(batch.width == 1)
        #expect(batch.tokens == [[2]])
        #expect(batch.mask == [[0]])
    }
}
