---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: The compaction smoke fold fails again, deterministically, on code CI passed twice
---
## What

Two tests of `CompactionSmokeIntegrationTests` fail on every run:

```
✘ "a fact planted at the very end of the folded span is still in the summary
   the fold stores" — CompactionSmokeIntegrationTests.swift:481:9
   Expectation failed: summary.contains(Self.plantedFactValue)

✘ "one fold against a real model: the summarizer answers within the fold's
   call budget, and the fold is applied rather than discarded"
   — CompactionSmokeIntegrationTests.swift:418:9
   Expectation failed: (1...2).contains(ceilings.count)
```

Both fail 3 of 3 whole-package runs, and the planted-fact test also fails
alone under `--filter aPlantedFactLateInTheSpanSurvivesTheFold`.

## The numbers repeat exactly

Every run prints the same fold line:

```
[compactionSmoke] summarizerCalls=3 ceilings=[617, 617, 628]
                  answerTokens=[703, 789, 810] spanTokens=643
                  summaryTokens=509 tokensBefore=713 tokensAfter=579
```

Decoding is greedy, so the fold is deterministic. This is not a flaky test.

## Why this is new

Task ^49dy082 fixed this same pair on 2026-08-31. It measured the fold at
`summarizerCalls=2 ceilings=[617, 617] answerTokens=[671, 517]
summaryTokens=517`, and it passed 13 of 13 runs. A reviewer then passed 5 of 5.
CI passed the integration job twice, on `387a553` and on `6be2294`.

Since `6be2294` no product file changed. The commits are `44af734` (kanban),
`2a3e0c0` (kanban plus `TurnCancellationTests.swift`) and `11760eb` (README).

So the same product code now folds differently. The summarizer takes 3 calls
where it took 2, and each answer is larger.

## What to look at first

- The fork revision is NOT the cause. Both `Package.resolved` files pin
  `mlx-swift-lm` at `41e9f41`, the revision the suite documents.
- `answerTokens[0]` moved from 671 to 703. The FIRST call already differs, so
  the input to the first call differs, or the model does.
- Read the model weights in the Hugging Face cache. The suite drives
  `compactionSmokeModel`, not the 18 GB `RealModels.standard`.
- A third summarizer call means both recovery rungs fired. Read
  `Summarization.resolveRepetitiveSummary` and `resolveOversizedSummary` to
  see which rung the third call belongs to.

## Acceptance Criteria
- [ ] The reason the fold now takes 3 calls is stated, with a measurement.
- [ ] Both tests pass. The assertions do not change.
- [ ] The whole integration package passes three times in a row.

## Tests
- [ ] `swift test --package-path IntegrationTests` three times.

## Note

Found while working ^echfvpm. That card is a real-model time limit and shares
no code with the fold. The failure blocks ^echfvpm's second acceptance
criterion, which asks for three green package runs. #router #compaction
#defect #real-model #ci