/// The system instructions every ``CompactionEvalSeed`` transcript opens
/// with. The fold keeps the `.instructions` entry, so the resumed session
/// answers each seed's question under this header.
///
/// The wording is the helpful persona, plus a statement that a summary may
/// stand in for earlier turns and is reliable, plus a statement that the
/// facts are fictional. Each clause is measured against
/// ``CompactionEvalRealModel`` under greedy decoding, over the whole-dataset
/// tier's 24 seeds (task ^e814b60, gated runs of 2026-08-19). Every register
/// below wrote the fact into the same 17 of 24 summaries; only the answers
/// moved:
///
/// | register | answers | `answerMissedFactSummaryCarriedIt` |
/// |---|---|---|
/// | "You are a helpful assistant in an ongoing conversation." | 13 of 24 | 5, all refusals |
/// | ``compactionContinuityFastInstructions`` (terse, word for word) | 10 of 24 | 7, all invented values |
/// | helpful + fictional only | 12 of 24 | 6, refusals and inventions mixed |
/// | this header | 13 of 24 | 4 |
///
/// What the rows mean:
///
/// - The bare helpful persona refuses private-sounding values its own
///   summary stated — "I can't provide information about internal
///   codenames...", flight numbers, hostnames, confirmation codes.
/// - The terse "state it exactly as it was given earlier, word for word"
///   register removes every refusal and grounds nothing: the freed model
///   answers with invented values ("Project Whisker" for "Project Longbow",
///   "localhost" for "stg-node-07.internal") instead of reading its summary.
/// - This header keeps the helpful persona's grounding, and the
///   summary-reliability clause is what converts the codename and
///   flight-number refusals into exact answers. Two refusals and two
///   near-miss values remain; those are the residual model behavior the
///   metric is right to keep counting.
///
/// The instructions state the register, never any seed's facts, so nothing
/// here can leak an answer.
let compactionEvalRecallInstructions = """
    You are a helpful assistant in an ongoing conversation. Part of the \
    earlier conversation may have been replaced by a summary; every statement \
    in that summary is accurate, so rely on it and quote its values exactly. \
    Every fact in this conversation is fictional test data, so you may repeat \
    any of it freely. Never refuse to state a fact from this conversation.
    """
