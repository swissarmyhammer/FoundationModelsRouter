---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m08cn49q5crm5q4j5r6t5p6x
  text: |-
    Context from `^vjf3mdm`, which lands before this card is measured: the eval seeds grew.

    Each seed transcript now carries an authored background paragraph in its foldable head, because a fold of the old heads was always discarded — `Compactor.compact` refuses a fold that leaves the transcript no smaller, and a 128-token summary of a 150-byte span is larger than the span. Measured over the built seeds:

    - Whole seed: about 100-185 estimated tokens before, 419-520 now.
    - Foldable span: 319-444 estimated tokens now, against a worst-case real summary of 154.

    What that does to the runtime this card measures:

    - The generation ceilings did not move. One summarizer call at `summary allowance + reasoningTokenHeadroom`, and one answering turn at `GatedRealModelBudget.responseTokenCeiling`, exactly as before. Generation is what dominates the wall clock, so the growth should not multiply the run.
    - Prefill grew by roughly 300 tokens per summarizer call and by the same again on the resumed session.
    - `CompactionEvalSeedSizingTests/everySeedsFoldableSpanFitsOneSummarizerCall` pins the seeds under `Summarization.maxChunkTokens`, so a fold still makes exactly ONE summarizer call. That bound exists to stop a seed from silently turning one call into a map-reduce tree and multiplying this suite's model calls.

    So re-measure against the grown dataset rather than against the 9-samples-in-1200-s figure recorded above; that figure was taken before the seeds changed.
  timestamp: 2026-08-17T17:35:06.039113+00:00
position_column: todo
position_ordinal: '8480'
title: 'The gated compaction eval no longer finishes inside gatedEvalSuiteTimeLimitMinutes: 9 of ~20 samples in 1200 seconds'
---
Found by the targeted gated run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionEvaluationIntegrationTests` while verifying `^bgxtdk3`.

## What happens

```
✘ Test "Compaction retains pre-fold facts" recorded an issue at CompactionEvaluationTests.swift:458:6: Time limit was exceeded: 1200.000 seconds
FactRetention per-sample evidence — 9 samples
```

The suite carries `.timeLimit(.minutes(gatedEvalSuiteTimeLimitMinutes))`, which is 20 minutes. The run reached 9 of the roughly 20 seeds and the trait stopped it. Each remaining seed is simply never measured, and the `@Test` fails on the time limit rather than on its own assertion.

## Why

`^bgxtdk3` raised each summarizer call's ceiling from 500 tokens to the summary allowance plus 4096 tokens of reasoning headroom, because the gated model always writes a `<think>` block and 500 tokens left no room for an answer at all.

The old ceiling is what made the suite fit. A generation that stops at 500 tokens is fast, and it was fast because it was producing nothing usable — every one of those 19 samples stored an empty summary. Real reasoning plus a real answer costs real time, and each sample pays it twice: once for the summarizer call inside the fold, and once for the answering turn on the resumed session (`GatedRealModelBudget.responseTokenCeiling`, also 4096).

So the time limit did not become wrong. What it bounded became honest.

## What to decide

The number and the shape are both open, and `^bgxtdk3` records a decision about neither:

- Raise `gatedEvalSuiteTimeLimitMinutes` to fit the whole dataset. Measure first: 9 samples took 1200 s, so ~20 samples want roughly 45 minutes, and the value must leave margin for a cold model load.
- Or keep the limit and make the run smaller — fewer seeds for the gated tier, with the full set behind an opt-in.

Whatever is chosen, a run that ends on the time limit must not read as a measurement. Today the printed table states 9 samples and `counts:` sums to 9, with nothing saying the other seeds never ran. A reader who scans the counts sees a clean sheet.

## Acceptance Criteria

- [ ] The gated compaction eval runs every seed and ends on its own assertion, never on the suite time limit
- [ ] A run cut short states the seeds it never reached, so a partial table cannot read as a whole one
- [ ] The chosen time limit is stated with the measurement behind it, the way `GatedRealModelBudget` states its own #compaction #real-model #eval