---
assignees:
- claude-code
position_column: todo
position_ordinal: '8880'
title: A fold's summary is unbounded, so compaction can save far less than the span it replaces — and the pipeline applies a fold that grew the transcript
---
Discovered by `^f80n046` while making the gated compaction suites deterministic. Not a determinism defect — the numbers below are now reproducible run to run — but a compaction-quality one, measured on real hardware for the first time.

## The measurement

`CompactionRoundTripIntegrationTests` with greedy decoding, `RealModels.standard`, 2048-token working context, 8 scripted turns:

- `tokensBefore` = 2074 estimated tokens
- old span (4 turns outside the recency window) ≈ 1068 estimated tokens
- the summary the fold produced: **3346 characters ≈ 837 estimated tokens**
- `tokensAfter` = 2143 (with the boundary's id manifest still counted) / ≈1843 once `^f80n046` stopped counting that manifest

So the summary was roughly **four fifths the size of the span it replaced**. After `^f80n046`'s estimator correction the fold nets an 11% shrink; before it, the fold reported a *larger* transcript than the one it replaced.

## Two gaps behind it

1. **No output budget on a summarizer call.** `CompactionSummarizer.summarize(_:)` takes a prompt and nothing else. `BackendCompactionSummarizer` calls `backend.respond(to: prompt, maxTokens: nil)`, which resolves to `LiveModelLoader`'s `defaultMaxTokens` of 8192. A fold knows its `TokenBudget` and knows the estimated size of the span it is folding; nothing carries either into the generation that produces the summary, so a model is free to answer at any length and routinely does.

2. **The pipeline applies a fold that made things worse.** `Compactor.compact` returns `Summarization`'s output whenever the stage produced one, without checking `tokensAfter` against `tokensBefore`. The oversized-tail path already knows how to return the original transcript unchanged with an empty `stagesApplied`; a fold that grew the transcript should take the same exit. As shipped, a session can swap its backend for a *larger* transcript and record a checkpoint saying so.

## Acceptance Criteria
- [ ] A summarizer call is bounded by something the fold knows — the budget's target, or the size of the span being folded — rather than by the generation path's generic 8192-token default
- [ ] `Compactor.compact` never returns a folded transcript larger than the one it was given; a fold that fails to shrink reports the shortfall the same way the oversized-tail case does
- [ ] Ungated coverage for both, with a summarizer fake that returns an oversized summary
- [ ] The gated round trip still passes three consecutive runs, and its `tokensAfter < tokensBefore` margin is reported

## Tests
- [ ] Ungated first (a fake summarizer needs no GPU); gated runs one at a time to confirm the real margin #phase-1