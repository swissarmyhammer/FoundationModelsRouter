---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: The real model still discards every compaction eval fold — 7 of 7 gated seeds report factInSummary=false with an empty stage list
---
Found by the sanctioned gated measurement run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` on 2026-08-17, while measuring the time limit for `^fz49qds`.

## What happens

The run passed. `factRetention` was 1.0 over all seven subset seeds, well over the 0.9 bar. Every one of the seven reports this shape:

```
- seed=db-port class=retained factInSummary=false folded=false summarizerCalls=1 stages=
  answer=6543.
  summary=<discarded>
```

- 7 of 7 seeds: `summarizerCalls=1`, an EMPTY stage list, `summary=<discarded>`.
- 7 of 7 seeds: `factInSummary=false`.
- 7 of 7 seeds: `class=retained`.

`summarizerCalls=1` with no stage applied is `Compactor.compact`'s shortfall exit. The summarizer ran, the summarizer answered, and the fold was then thrown away because `tokensAfter >= tokensBefore`. The transcript the resumed session was handed is the ORIGINAL one.

## Why the pass is a pass for the wrong reason

`class=retained` says the answer carried the key phrase. It did — because the planted fact was still sitting in the transcript verbatim. No summary was involved in any of the seven answers. A metric of 1.0 over seven discarded folds measures the model's ability to read a transcript it was given whole, and says nothing at all about compaction.

This is the same condition `^vjf3mdm` closed, reappearing against the real model. That card's third acceptance criterion — "The gated eval reports `factInSummary=true` on the large majority of seeds" — is still open, and this is the measurement that shows it.

## Why the hermetic gate did not catch it

`CompactionEvaluationHermeticTests/everySeedFoldSurvivesARealisticSummary` folds every seed against `RealisticSummaryLengthSummarizer`, and it passes: every seed's `stagesApplied` is `[ToolOutputElision, TurnTruncation, Summarization]`. So the hermetic gate says the fold survives, and the real model says it does not. One of the two is wrong about what a real summary costs.

`RealisticSummaryLengthSummarizer` answers with exactly `maxTokens - reasoningTokenHeadroom` tokens' worth of bytes, at `compactionEvalMeasuredBytesPerToken`. The real model's summary is evidently larger than that once it is a stored entry, or the entry's own metadata costs more than the estimate allows for. `CompactionEvalSeedSizingTests` states the arithmetic the gate rests on, and one of its two inputs — the worst-case summary size, or the bytes-per-token rate — does not match what the run really produced.

## What to find out first

The run prints `<discarded>` and nothing else about the summary that was discarded, because `CompactionResult.summary` is `nil` on the shortfall path. So the run cannot say HOW MUCH too large the fold was. That number is the first thing to get: `Compactor.compact`'s `tokensBefore` and `tokensAfter` on the discarded path, printed per sample, would say whether the miss is a few percent or a multiple.

## Acceptance Criteria

- [ ] The gated eval reports `factInSummary=true` on the large majority of seeds, so `factRetention` measures a summary rather than the original turns
- [ ] The hermetic gate agrees with the real model: a seed the hermetic suite says folds is a seed the gated run folds
- [ ] A discarded fold states the size it missed by, not only that it was discarded #compaction #defect #real-model #eval