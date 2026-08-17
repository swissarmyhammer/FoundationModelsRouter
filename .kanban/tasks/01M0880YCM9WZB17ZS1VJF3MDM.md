---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Compaction eval seeds are too small for a real summary to shrink them, so 8 of 9 gated folds are discarded and factInSummary cannot be measured
---
Found by the targeted gated run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` while verifying `^bgxtdk3`.

`^bgxtdk3` closed the empty-summary defect: the summarizer now writes real text. That change made a second condition visible, and this task is that condition.

## What happens

Of the 9 samples that completed, 8 report:

```
- seed=<name> class=retained factInSummary=false folded=false summarizerCalls=1 stages=
  summary=<none>
```

`summarizerCalls=1` with an EMPTY `stages` list is `Compactor.compact`'s shortfall exit: `Summarization` ran, the summarizer answered, and the fold was then discarded because `tokensAfter >= tokensBefore`. `CompactionResult.summary` is `nil` on that path, so the table prints `<none>` and `folded=false`.

The one seed that did fold — `codename` — behaved correctly end to end:

```
- seed=codename class=retained factInSummary=true folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
  summary=2. Stated facts
- the internal codename for the new feature is "Project Longbow".
```

## Why

The guard is correct and is doing its job. `Compactor.compact` refuses a fold that leaves the transcript no smaller, because swapping real conversation for a paraphrase that costs the same buys nothing.

The seeds are what changed meaning. A folded transcript is the header, the synthesized summary entry — text plus a `CompactionSegment` carrying `liveWindowEntryIds`, `foldedEntryIds`, the token counts and the stage list — and the untouched recency window. On a seed this small the recency window is most of the transcript, so the fold trades one or two old turns for an entry whose own metadata costs bytes. The margin was always thin. It only ever cleared because the stored summary held zero characters.

So `retained=9` is a pass for the wrong reason on 8 of the 9: the transcript came back UNCHANGED, and the resumed session answered from the original turns rather than from a summary. The dataset cannot measure what it exists to measure.

## Why this is its own task

Two answers are open and neither belongs to `^bgxtdk3`, which records no decision about either:

1. Grow the seed transcripts so a real summary is genuinely smaller than the span it replaces. `compactionEvalDefaultBudget` and the fixtures move together, and `defaultBudgetForcesSummarizationStage` already pins that the budget forces the stage — it does not pin that the fold is APPLIED.
2. Let the eval state the difference. A sample whose fold was discarded is neither `summaryLostFact` nor `foldProducedNoSummary`; it is a fold that was never applied, and no case names that today.

Prefer 1, and add a hermetic assertion beside `defaultBudgetForcesSummarizationStage` holding every seed to `stagesApplied.last == Summarization.stageName` under a fake summarizer whose answer is realistic in length — the ungated suite then fails the moment a seed stops folding, instead of a gated run discovering it.

## Acceptance Criteria

- [ ] Every seed's fold is APPLIED, not discarded: a hermetic test holds each seed to `stagesApplied == ["ToolOutputElision", "TurnTruncation", "Summarization"]` against a summarizer whose answer is the length a real one writes, not a two-word stub
- [ ] A discarded fold is legible in the eval table rather than reported as `<none>`, which reads the same as a stage that never ran
- [ ] The gated eval reports `factInSummary=true` on the large majority of seeds #compaction #defect #real-model