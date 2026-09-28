/// A batch of token rows, right-padded to one width, with the key-padding mask
/// of each row.
///
/// `LiveEmbeddingContainer.embed(texts:in:)` gives ``tokens`` to the model and
/// gives ``mask`` to the model AND to the pooling (task ^nmmnn7k). The mask
/// comes from the token count of each row, not from the token values: the pad
/// is the EOS id of the tokenizer, and a real EOS that the tokenizer adds at
/// the end of a text must stay in the mask.
///
/// Plain Swift arrays, so a unit test reads the batch with no model and no GPU.
struct PaddedTokenBatch: Equatable {
    /// The value of ``mask`` at a real token.
    static let realToken: Int32 = 1

    /// The value of ``mask`` at a pad.
    static let pad: Int32 = 0

    /// The width of each row: the token count of the longest row, and at least
    /// one, so a batch of empty rows is still a valid tensor shape.
    let width: Int

    /// Each row of the input, with `padToken` added at the end up to ``width``.
    let tokens: [[Int]]

    /// For each row, ``realToken`` at each position that holds a token of the
    /// input and ``pad`` at each position that holds a pad.
    let mask: [[Int32]]

    /// Pads `rows` on the right to one width and builds the mask of each row.
    ///
    /// - Parameters:
    ///   - rows: The token ids of each text, as the tokenizer encoded them.
    ///   - padToken: The token id that fills each row up to ``width``.
    init(rows: [[Int]], padToken: Int) {
        let width = rows.reduce(into: 1) { $0 = max($0, $1.count) }
        self.width = width
        tokens = rows.map { row in
            row + Array(repeating: padToken, count: width - row.count)
        }
        mask = rows.map { row in
            Array(repeating: Self.realToken, count: row.count)
                + Array(repeating: Self.pad, count: width - row.count)
        }
    }

    /// The shape of ``tokens`` and of ``mask`` as a tensor: [rows, ``width``].
    var shape: [Int] {
        [tokens.count, width]
    }
}
