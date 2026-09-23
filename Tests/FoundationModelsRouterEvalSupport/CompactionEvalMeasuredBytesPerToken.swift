/// The number of UTF-8 bytes that one token of English prose costs, under
/// the tokenizers of the models that the gated evals run.
///
/// The continuity tests count the bytes of a fixture step and divide by this
/// rate to get a token count. A fixture that is sized by a character count
/// and not by a tokenizer is how `CompactionRoundTripIntegrationTests` got
/// below its own trigger (task ^wnj3ka3). Thus the tests convert bytes into
/// the tokens that the model counts.
///
/// The measurement: each piece of the prose corpus is encoded on its own, and
/// the token counts are added, with the `tokenizer.json` of each model from
/// the local Hub cache. The corpus was the prose of the first compaction eval
/// dataset: 41 pieces and 9824 UTF-8 bytes. Task ^k25d0xm deleted that
/// dataset, and the rate stays as it was measured.
///
/// | tokenizer | tokens | bytes for each token |
/// |---|---|---|
/// | Muse Glimmer 30B | 2055 | 4.781 |
/// | Llama 3.2 1B | 2066 | 4.755 |
/// | Qwen2.5 3B | 2074 | 4.737 |
///
/// This value keeps the LARGEST of those rates, rounded up. Each use of this
/// constant converts bytes of prose into tokens. The largest rate gives the
/// smallest token count, so a step that is over a threshold under this rate
/// is also over it live, and each gate that this value feeds stays strict.
let compactionEvalMeasuredBytesPerToken = 4.79
