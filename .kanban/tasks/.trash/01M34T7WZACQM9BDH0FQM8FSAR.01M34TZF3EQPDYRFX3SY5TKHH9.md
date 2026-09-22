---
assignees:
- claude-code
depends_on: []
position_column: todo
position_ordinal: '9080'
title: Derive the summary size from the compaction target; delete summaryTokenRatio and statedBudgetShareOfContent
---
## Decision (from the owner, 2026-09-22)

`Summarization.summaryTokenRatio` (0.25, `Compaction/Summarization.swift:49, 111`) and `Summarization.statedBudgetShareOfContent` (0.75, `:69`) are invented sizes and must go. The size a summary may have follows from the compaction target: the summary may be as large as leaves the transcript at `TokenBudget.target`, capped by the byte budget that keeps the compaction a shrink.

## Why

- 0.25 came with commit c23842f as a knob with no reason. 0.75 is a prompt-wording calibration from the evals that only applies to spans under about 670 tokens.
- The compaction already has a target. A fixed ratio ignores it: on a transcript far over target the summary may be too large to land it; on one just over target the model is told to cut to a quarter for no reason.

## Sites

- `Summarization.swift:47-49, 111, 116`: `summaryTokenRatio` and its init parameter.
- `:67-69`: `statedBudgetShareOfContent`. `:750-757` `statedBudgetBytes(condensing:)`. `:462-467`: the prompt line "Size budget: about N words".
- `:759-763` `maximumSummaryTokens`, `:765-769` `summaryTokenAllowance(ingesting:)`: the ratio's cap (the floor card also touches these).
- `Compaction/Compactor.swift`: how the stage receives the budget. `Summarization.apply` does not get the `TokenBudget` today (see c23842f's note). Pass it, or pass the derived allowance in tokens.
- Every place that constructs `Summarization(summaryTokenRatio:)`: `RoutedSessionActorForking.swift` (fork), `SessionConfiguration`, the sidecar, tests and evals.
- Tests: `SummarizationStageTests`, `CompactionTokenAccountingTests`, `CompactionEvalTiers` and the eval datasets that state the ratio.

## Do this

1. Give the summarization stage the compaction's target in tokens and the size of everything the compaction keeps (instructions, the recent turns, protected outputs, the pending-runs rendering). The allowed final summary size is `target − kept`, capped by `summaryByteBudget` in tokens. When it is not positive, the stage cannot land the target with a summary; return the transcript unchanged and let the deterministic stages report the shortfall as they do today.
2. The prompt states that derived size. Delete `statedBudgetShareOfContent` and `statedBudgetBytes`.
3. An intermediate map-reduce call sizes its summary to what the next call can ingest; derive that from the chunk size the stage uses (see the `maxChunkTokens` card).
4. Delete `summaryTokenRatio`, its init parameter, and every construction site's argument. The sidecar stops recording it; a restore ignores an old sidecar's value.
5. If an eval shows the model overshoots the stated size and needs a lower stated number, do not add a constant. Record the measurement on a new card with the eval that produced it.
6. Update the tests: a transcript 3,000 tokens over a 10,000-token target with 4,000 tokens kept gets a stated summary size of 6,000 tokens (or the byte budget, whichever is lower); a case where `target − kept` is not positive returns the transcript unchanged.

## Order

After the `minimumSummaryTokens` card; both rewrite the allowance functions.

## Acceptance

- `rg 'summaryTokenRatio|statedBudgetShareOfContent|statedBudgetBytes'` finds nothing.
- The tests above pass. All tests pass.
- The real-model eval tier runs; its numbers are recorded on this card. #compaction #limits