---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m35ans8bz0xaf9ayvajanybx
  text: |-
    Research and first implementation notes.

    - The library now compacts in one call. `Summarization.plan` builds the call: the input is the compaction prompt plus the whole live context, the instructions included. The allowed size is `targetTokens - instructions - protected entries - pending-runs rendering`. The prompt states it as "Size budget: about N tokens." When the size is not positive, the result has `shortfall = .targetLeavesNoRoomForSummary`.
    - `CompactionCall.outputCeiling(for:)` holds the choice by window. The flash tier runs when `window - input >= allowed size`. The own model runs when `window - input > 0`. The ceiling is `window - input`. When no tier can run, the result has `shortfall = .inputFillsSummarizerWindow`.
    - A reading of the card: the check for the own model is "window - input > 0", not "window >= input + allowed size". The reason: at the kept defaults (trigger 0.80, target 0.50), input (0.8 W) + summary (0.5 W) is more than W. The stricter check would stop every automatic compaction. The card's own words ("whose window holds the live context by construction", "the live context is at the window") name the failure as no room after the input. The flash tier keeps the stricter rule, word for word.
    - The new snapshot is the instructions, then the summary entry (checkpoint and pending-runs text), then the protected tool outputs with their calls. The did-it-shrink check returns the live context unchanged with `shortfall = .summaryDidNotShrinkContext`.
    - The session measures with its tokenizer before the call. After the call, the next turn's `usage.input` replaces the count (`compactedUsage` rescales it).
    - Gone: `ToolOutputElision`, `TurnTruncation`, `CompactionStage`, `TranscriptTurns`, the stage loop, `compactionKeptOverTarget`, the deterministic tier and `CompactionSegment.appendingDeterministicBoundary`, `RecordingLanguageModel.noteCompaction(_:result:)`, `CompactionResult.summaryCut`, every chunk/reduce/condense/repetition/headroom constant and function. `Summarization` has no settings now. An old sidecar still decodes, and a restore ignores its values.
    - New: `CompactionResult.summarizerTier` and `CompactionResult.shortfall` (`CompactionShortfall`). They record which tier ran and why a compaction left the context as it was. The span writes `compaction.tier` only when a summary applied.
    - The caller-driven `compact()` offers the own model only, as before. The automatic compaction offers flash, then the own model. When flash fails, the own model runs. The abandon-on-cancel rule stays.
    - `CompactionPrompt.default` is now `router-default-v5`. It states the size budget in tokens.
  timestamp: 2026-09-22T19:49:52.523935+00:00
- actor: claude-code
  id: 01m35e4y7megvece1hmmvk3k81
  text: |-
    ### implement — changed
    - evidence: 79 paths. Sources (Compactor, Summarization, CompactionSegment, ToolOutputProtection, CompactionPrompt, RoutedSessionActorCompaction, RecordingLanguageModel, doc comments). Deleted ToolOutputElision, TurnTruncation, CompactionStage, TranscriptTurns. Unit tests: the four old test files are deleted; OneCallCompactionTests, OneCallCompactionTierTests and CompactionPromptTests are new; the tests of behavior that stays are rewritten. The evals, the eval support, the real-model support, the IntegrationTests, the tool and the example lose the deleted parameters.
    - The checkpoint now states the measured scale (`CompactionSegment.restatingSizes`), so a restore reports the same fill as the live session.
    - Acceptance rg over Sources: no match.

    ### test — green
    - evidence: `swift test`: 1297 unit tests in 145 suites passed (2 known issues, not new in this change), 1 public-surface test passed, 83 eval tests in 10 suites passed. `swift build --package-path IntegrationTests --build-tests`: Build complete. The one build warning, "missing creator for mutated node … mlx-swift_Cmlx.bundle", comes from the build system and is not new.

    ### Real-model eval tier (gated) — the numbers
    Command: `swift test --package-path IntegrationTests --filter FoundationModelsRouterEvalIntegrationTests`. Model: Qwen2.5-3B-Instruct-4bit, greedy decoding, on this machine.
    - Fact retention: FAIL against its floors. 7 of 7 seeds ran, and each made exactly 1 summarizer call. Summary share 3 of 7 (0.43). Answer share 4 of 7 (0.57). The floors are 0.71 (5 of 7). Before this change the same tier measured 6 of 7 on both sides.
      - budget-cap-tool-and-owner: summaryLostFact, 1936 B
      - db-port: retained, 155 B
      - encryption-algorithm: discarded (summary 599 tokens, span 507, ceiling 7114), 2534 B
      - license-key-and-region: retained, 1555 B
      - sesame-allergy: summaryLostFact, 1566 B
      - three-facts-long-project-brief: retained, 415 B
      - three-facts-support-escalation: summaryLostFact, 299 B
      - In the lost seeds, the summary lists the assistant's acknowledgements as the facts.
    - Continuity: PASS. 4 tasks; compactionOccurred 1.0, factsSurvived 1.0, answersCorrect 1.0.
    - Smoke suites (Llama-3.2-1B): the answer runs to the ceiling (`ceilings=[2821] answerTokens=[2821]`), and the did-it-shrink check discards it (`summaryDidNotShrinkContext(snapshotTokens: 2866)` against 744). `AutoCompactionTriggerIntegrationTests` shows the same result. `CompactionSpikeIntegrationTests` passes.
    - For the owner: the card sets the output ceiling at window − input with no other bound. A small model that does not keep to the stated size writes until that ceiling. The did-it-shrink check then rejects the summary. The code follows the card. I made no change to the floors, and I added no bound.
    - `compactionEvalDefaultBudget` is now `TokenBudget(limit: 418, trigger: 0.80, target: 1.0)`. The old 40-token target was under the 78-token recall instructions, so every compaction stopped. The measurement is in its doc comment.
  timestamp: 2026-09-22T20:50:34.868885+00:00
- actor: claude-code
  id: 01m35fv7qhcph33zgxgqsxx6ge
  text: |-
    ### commit — changed
    - evidence: 18965cd feat(compaction): compact in one summarizer call over the whole live context

    ### review — findings
    - evidence: 2 findings. Tests/FoundationModelsRouterEvalSupport/CompactionEvaluation.swift:133, Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:101
    - next: implement the findings, test, commit, review.
  timestamp: 2026-09-22T21:20:14.065740+00:00
- actor: claude-code
  id: 01m35fxy6xvmg5nvewfedv5pee
  text: |-
    ### finish iteration 1 — review: findings
    - implement: changed — 18965cd: the one-call compaction across Sources, the tests, the evals, IntegrationTests, the tool and the example
    - test: green — `swift test`: 1297 unit tests in 145 suites (2 known issues, not new), 1 public-surface test, 83 eval tests: all pass. `swift build --package-path IntegrationTests --build-tests`: Build complete
    - commit: 18965cd
    - review: findings — Tests/FoundationModelsRouterEvalSupport/CompactionEvaluation.swift:133 (magic-numbers-swift), Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:101 (swift/fluent-usage)

    ### implement — changed
    - evidence: The target is now the named constant `compactionEvalDefaultTargetTokens` (CompactionEvaluation.swift). The test helper is now `compact(session:)`, and all call sites use it (ToolOutputProtectionSessionTests.swift). Both findings are checked.

    ### test — green
    - evidence: `swift test`: 1297 unit tests in 145 suites passed (2 known issues, not new), 1 test passed, 83 eval tests passed. The only build warning is the old build-system "missing creator" warning.
  timestamp: 2026-09-22T21:21:42.621742+00:00
depends_on:
- 01M34SPS7H39SK38H95M39WMX1
- 01M34VATXAFNGB9WBF6XJK0PP8
- 01M3599BYH1WBNJA33FN1KHNXA
position_column: review
position_ordinal: '80'
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

## Review Findings (2026-09-22 15:50)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 76 file(s) reviewed, 3 not reviewed.

- [x] `Tests/FoundationModelsRouterEvalSupport/CompactionEvaluation.swift:133` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift:101` `swift/fluent-usage` — Omit the first argument label only for value-preserving conversions. Compacting a session is a transformation, not a value-preserving conversion, so the first parameter should have a label. Change to `private static func compact(session: RoutedSession, ...)` so call sites read as `Self.compact(session: session, ...)` with semantic clarity of what is being transformed.