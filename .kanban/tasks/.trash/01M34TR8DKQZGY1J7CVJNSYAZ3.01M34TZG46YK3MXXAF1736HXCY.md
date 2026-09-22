---
assignees:
- claude-code
depends_on: []
position_column: todo
position_ordinal: '9180'
title: Summarize the whole span in one call; delete chunking, map-reduce, maxChunkTokens and reasoningTokenHeadroom
---
## Decision (from the owner, 2026-09-22)

`Summarization.maxChunkTokens` (2,000) and `Summarization.reasoningTokenHeadroom` (8,192) (`Compaction/Summarization.swift:45, 54, 110, 112`) are invented numbers and must go. So must the mechanism they drive. The owner's words: "compaction should be over a full transcript that is obviously shorter than the context limit and the summarization prompt. There is NO NEED to chunk this or map reduce."

The span a compaction summarizes is part of a live transcript that already fits the session's window. The summarization prompt plus that span fits one call of a model with that window. One call.

## What goes

- `maxChunkTokens`, `reasoningTokenHeadroom`, their init parameters and docs (`:40-54, 106-118`).
- `Summarization.chunk(_:maxTokens:)`, `chunkStrings(_:maxTokens:)`, the map step in `summarize(_:prompt:summarizer:)` (`:373-393`), and `reduce(_:prompt:summarizer:)` with its no-progress fallback (`:395-425`). `summarySeparator` if nothing else reads it.
- `outputTokenCeiling(forSummaryAllowance:)` (`:737-739`): the ceiling is no longer allowance + headroom.
- `maximumSummaryTokens` (`:759-763`), which is sized from `maxChunkTokens`.
- Every construction site's `maxChunkTokens:` and `reasoningTokenHeadroom:` argument: `RoutedSessionActorForking.swift`, `SessionConfiguration`, the sidecar, the evals (`CompactionEvalTiers`, `CompactionEvalDataset`), the examples, and the tests.
- Tests that exercise chunking and reduce in `SummarizationStageTests.swift` (the file is 330 KB; most of it is chunk and reduce cases) and `CompactionTokenAccountingTests`.

## What replaces it

1. `summarize(_:prompt:summarizer:)` renders the whole span and makes one `summarizeOnce` call.
2. The call's input is the assembled prompt plus the span. Its output ceiling is what the summarizer model's window leaves after that input: `window − input tokens`. The session passes the summarizer model's window with the summarizer (`CompactionSummarizer` gains it, or the actor passes it to `apply`). No headroom constant; the reasoning and the answer share what the window leaves.
3. The size the prompt states is the derived summary size from the "summary size" card (target − kept, capped by the shrink byte budget).
4. When the input does not fit the summarizer model's window (a flash model with a smaller window than the session's own), that summarizer cannot take the span. Fall to the next tier as the tier chain already does (flash → own model → deterministic). The session's own model always fits, because the span came from its window. Record the fallback reason on the compaction event.
5. The condense re-ask stays as one more single call under the same ceiling.

## Order

After the `minimumSummaryTokens` card and the "summary size" card. All three rewrite the allowance functions; land them in that order.

## Acceptance

- `rg 'maxChunkTokens|reasoningTokenHeadroom|chunkStrings|func chunk\(|func reduce\('` finds nothing in `Sources`.
- A test with a 20,000-token span and a 32,768-token summarizer window makes exactly one summarizer call, whose ceiling is the window minus the input.
- A test with a span that does not fit a 4,096-token flash window falls to the own-model tier and records why.
- All tests pass. The real-model eval tier runs; its numbers are recorded on this card. #compaction #limits