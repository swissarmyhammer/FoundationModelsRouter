---
assignees:
- claude-code
depends_on:
- 01M34SPS7H39SK38H95M39WMX1
- 01M34VATXAFNGB9WBF6XJK0PP8
- 01M3599BYH1WBNJA33FN1KHNXA
position_column: todo
position_ordinal: '9380'
title: 'Make compaction one call: current context + compaction prompt → a snapshot of instructions + summary'
---
## Decision (from the owner, 2026-09-22)

Compaction is one summarizer call over the current state of the context with the compaction prompt. Its result is a new snapshot that restarts the live context with instructions + summary. The recorded transcript keeps the whole history, as it does today (append-only, one checkpoint entry). Nothing else.

The owner's words: "just taking 'the current state of the context' + 'a compaction prompt' and creating a new compaction snapshot that restarts the context with a smaller set of text while preserving the whole historical transcript. i never asked for map reduce or chunking." And: "the system prompt 'counts' to the context limit."

This card supersedes the three partial cards of 2026-09-22 (the summary floor, the summary size from target, and one call without chunking). They are deleted; their content is here.

## What goes

In `Compaction/Compactor.swift`:
- `ToolOutputElision` and `TurnTruncation` (`Compaction/ToolOutputElision.swift`, `Compaction/TurnTruncation.swift`), `Compactor.stages(protecting:)`, the stage loop (`:173-186`), `compactionKeptOverTarget` and the "deterministic-only" result shape. `CompactionStage` if nothing else conforms.
- The deterministic tier of the summarizer tier chain (flash → own model → deterministic). The chain becomes: flash when its window holds the input, else the session's own model. Record which one ran on the compaction event.

In `Compaction/Summarization.swift`:
- `keepRecentTurns` (also in the two deleted stages), `maxChunkTokens`, `reasoningTokenHeadroom`, `summaryTokenRatio`, `minimumSummaryTokens`, `statedBudgetShareOfContent`, `summaryBytesPerWordEstimate`, `maximumRepeatedLineShare`, `minimumLinesForRepetitionCheck`, `shrinkMarginBytes`.
- `chunk`, `chunkStrings`, the map step, `reduce`, `summarySeparator`.
- The condense re-ask (`resolveOversizedSummary`, `condense`, `makeCondensePrompt`).
- The repetition detector (`isRepetitive`).
- `outputTokenCeiling(forSummaryAllowance:)`, `summaryTokenAllowance(...)`, `maximumSummaryTokens`, `statedBudgetBytes`.

Every construction site's arguments for the deleted parameters: `RoutedSessionActorForking.swift`, `SessionConfiguration`, the sidecar (a restore ignores an old sidecar's values), `RoutedSessionActorCompaction.swift`, the examples, the evals, the tests.

## What stays

- The compaction prompt (`CompactionPrompt`), host-configurable.
- `TokenBudget` with `limit`, `trigger`, `target`, `hardCeiling`, `toolOutputLimit`.
- The did-it-shrink check (`Compactor.swift:213-214`): a summary that does not shrink the live context is rejected, and the compaction reports that it did nothing.
- `ToolOutputProtection`, the host rule: a protected output is kept word for word in the new snapshot, next to the summary.
- The checkpoint (`CompactionSegment`), the append-only journal, the restore path, the run-plane rendering of pending runs in the snapshot.

## The one call

1. Input = the assembled compaction prompt + the whole current live context (the instructions entry and every entry after it, rendered as the prompt renders a span today). The instructions count.
2. The summarizer model is the flash model when `flash window ≥ input tokens + the summary's allowed size`; else the session's own model, whose window holds the live context by construction. No chunking. When even the own model cannot hold input + summary (the live context is at the window), the compaction reports that it cannot run; the hard-ceiling and overflow paths handle that turn as they do today.
3. The summary's allowed size, in tokens, = `budget.targetTokens − instructions tokens − protected outputs tokens − pending-runs rendering tokens`. The prompt states that size. When it is not positive, the compaction reports that it cannot land the target; it does not run.
4. The call's output ceiling = `summarizer window − input tokens`. No headroom constant.
5. The new live context = instructions + the summary entry (with the checkpoint) + the protected outputs + the pending-runs rendering. No recent turns kept verbatim.
6. Measure with the session's tokenizer where a count is needed before a call; the engine's `usage.input` after it. Say in the code which is used where.

## Tests

- Replace `SummarizationStageTests.swift` (330 KB, mostly chunk and reduce cases), `CompactionStageTests.swift`, `CompactorPipelineTests.swift` and `CompactionTokenAccountingTests.swift` with tests of the one call: input composition (instructions included), summarizer choice by window, allowed size from target, ceiling from window, the shrink check, protection kept, the snapshot shape, the checkpoint, and a restore that rebuilds instructions + summary.
- The eval datasets and tiers (`Tests/FoundationModelsRouterEvalSupport`, `FoundationModelsRouterEvals`) lose the deleted parameters. Run the real-model eval tier and record its numbers on this card.

## Acceptance

- `rg 'ToolOutputElision|TurnTruncation|keepRecentTurns|maxChunkTokens|reasoningTokenHeadroom|summaryTokenRatio|minimumSummaryTokens|statedBudgetShareOfContent|summaryBytesPerWordEstimate|maximumRepeatedLineShare|minimumLinesForRepetitionCheck|chunkStrings|isRepetitive|makeCondensePrompt'` finds nothing in `Sources`.
- A compaction over a 100,000-token live context with a 4,000-token instructions entry, a target of 50,000, and a flash model of 32,768 tokens runs on the session's own model, in one call, with a stated summary size of 46,000 and a ceiling of window − input.
- A summary that does not shrink the context is rejected and the compaction reports it.
- All tests pass.

## Order

After ^m39wmx1 (the overflow retry target), which reads `budget.target` the same way. Land this before ^9ddjkjm, which calls `performAutoCompaction`. #compaction #limits