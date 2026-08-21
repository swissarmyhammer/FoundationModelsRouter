---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'The continuity eval tier is red on main: the 1B loses the facts under the redesigned prompt, and only the 3B that breaks the two-minute budget keeps them'
---
`CompactionContinuityEvaluationIntegrationTests` FAILS on unmodified `main`. Measured on 2026-08-20 with `swift test --package-path IntegrationTests --filter CompactionContinuityEvaluation`, against `mlx-community/Llama-3.2-1B-Instruct-4bit`:

```
factsSurvived   measured 0.1  against compactionContinuityFastFactsSurvivedFloor  = 0.6
answersCorrect  measured 0.0  against compactionContinuityFastAnswersCorrectFloor = 0.3
suite wall clock 92.8 s, against gatedEvalSuiteTimeLimitMinutes = 2 (120 s)
```

Task ^m03heaa found this. It ran the tier twice: once with its own uncommitted work in the tree, and once with the tree stashed back to `main`. Both runs gave the same 0.1 and 0.0 and the same two issues. So the failure belongs to `main`, and ^m03heaa did not cause it.

## The cause

The two floors are the 1B model's own measured baselines from 2026-08-19. Task ^xx02yn6 then redesigned the summarization prompt and the span-budget trim for Qwen3.8-27B, the standard model. That redesign takes the 1B the OTHER way, and ^m03heaa measured the same effect on the fact-retention tiers: the 1B fell from 6 of 7 to 2 of 7 stored subset summaries. The continuity tier shows the same damage, and its floors were never re-measured after ^xx02yn6.

The wall clock moved too: this tier measured 26.2 to 41.4 s on 2026-08-19, and it measures 92.8 s now. That is 77 percent of its two-minute limit. A gated run that reaches its limit takes a Metal abort (signal 6 or 11) instead of a failure — see fork card ^3axg80k.

## Why a person must decide

Two standing constraints cannot both hold with any subject measured so far:

- The floors must be met by the subject. Task ^m03heaa measured this tier under `mlx-community/Qwen2.5-3B-Instruct-4bit` and it PASSES its floors there.
- Task ^k0d30s4 gives each integration test a budget of two minutes, which `gatedEvalSuiteTimeLimitMinutes = 2` states. Under the 3B this tier measured 219.1 s, which is past that budget.

So the 1B meets the budget and loses the facts, and the 3B keeps the facts and breaks the budget. There is no third option on the table.

## What to build

Pick ONE of these, and record the reason:

1. Move the continuity tier to Qwen2.5-3B and make it fit the two-minute budget — for example, fewer tasks, fewer steps for each task, or a smaller synthetic fold target. Re-measure the floors against the new subject and the new shape.
2. Move the continuity tier to Qwen2.5-3B and make it an opt-in tier with its own larger limit, as `CompactionEvalFullDatasetIntegrationTests` already is. The everyday command then skips it, and ^k0d30s4's budget stays true for what the everyday command runs.
3. Find a third small model the redesigned prompt serves, as ^m03heaa did for the fact-retention tiers, and re-derive the floors from its measurements.

Do NOT lower the floors to the 1B's new 0.1 and 0.0. That is the exact defect ^m03heaa was opened to correct on the fact-retention side: a floor that low lets a change break almost every task and still pass.

Task ^m03heaa leaves `CompactionContinuityRealModel` in place — the continuity tier's own model constant, holding the 1B — so this card can change one constant and one set of floors.

## Acceptance Criteria

- [ ] `swift test --package-path IntegrationTests --filter CompactionContinuityEvaluation` is green
- [ ] The floors are re-derived from measurements of the CURRENT subject under the current prompt, with the standing rule (the measured share minus one task of margin)
- [ ] The floors are high enough that one lost task is visible
- [ ] The tier's wall clock is recorded, and it is inside the limit its suite states, with margin
- [ ] Each doc comment names the run its number was measured on

#compaction #eval #real-model