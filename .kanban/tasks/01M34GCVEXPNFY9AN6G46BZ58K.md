---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37awypqgat5h67afcab5mvs
  text: |-
    ### implement — design decisions and result
    - Reuse of the ^9ddjkjm path: a new private `compactAndContinue(attempt:continuationPrompt:body:)` holds the compaction, the `.compaction` event, the stop rule and the next `runTurnAttempt`. `continueAfterCompactionYield` and the new `continueAfterCeilingStop(attempt:body:)` both call it. `StoppedAttempt` carries the attempt facts for both.
    - Detection: `finishTurn` and `finishTurnAndRequeueIfUnattached` now also return the `FinishReason` they already computed. `runTurnAttempt` reads it after the success path. `compactsAfterCeilingStop(_:)` is true when the reason is `.maxTokens`, the session has a budget, no stop is outstanding, `compactionYieldsStopped` is false, and `usageState.measuredTokens >= triggerTokens`.
    - The continuation runs OUTSIDE the `do`/`catch` of `runTurnAttempt`. Reason: the cut attempt is already recorded; a throw from the compaction or the next attempt must not record it a second time or go into `recoverFailedAttempt`.
    - Continuation prompt: a named constant `ceilingStopContinuationPrompt` = "The context was compacted. Your last output was cut off at the token ceiling. Continue the task."
    - Limit (card step 3): no count, because the owner's rule is "no invented limits". The one stop rule is the one ^9ddjkjm uses: when a compaction inside the turn applies no summary, `compactionYieldsStopped` is set, and the turn does not compact inside the turn again. A compaction that applies a summary makes the context smaller, so a next ceiling stop over the trigger is new progress, not a loop.
    - Return value: the turn returns the text of the continuation attempt. The cut text stays in the stream, in the record and in the summary.
    - Under the trigger: no compaction; the turn ends as today with `finishReason == .maxTokens`.
    - Discovery: the compaction counts the transcript with the session's own counter, not with the engine usage. A test whose transcript text is small makes a no-op compaction (tokensBefore == tokensAfter, no summary). The over-trigger test therefore writes a cut text that fills the context.
    - Tests: `Tests/FoundationModelsRouterTests/CeilingStopCompactionTests.swift` (2 tests), helper `Tests/FoundationModelsRouterTests/Helpers/CeilingStopCompactionModel.swift`. No real-model test (per the dispatch).
    - test: green — `swift test`: 1312 tests in 149 suites passed (2 designed known issues), 1 test and 83 eval tests passed. `swift build --build-tests` in `IntegrationTests`: Build complete.

    ### implement — changed
    - evidence: Sources/.../Session/RoutedSessionActorCompactionYield.swift, RoutedSessionActorTurnExecution.swift, RoutedSessionActorRecording.swift, RoutedSessionActor.swift, RoutedSessionActorTurnGating.swift; Tests/.../CeilingStopCompactionTests.swift, Tests/.../Helpers/CeilingStopCompactionModel.swift
    - next: commit, then review HEAD~1..HEAD.
  timestamp: 2026-09-23T14:32:16.343099+00:00
depends_on:
- 01M34GC0FRM3175J7XJJ6B24GD
- 01M34GCP8GJ5ACP29ZH9DDJKJM
- 01M34H27HEABW92JPTM5E8G7PZ
position_column: doing
position_ordinal: '8180'
title: Compact and continue when an append stops at the token ceiling
---
## Problem

When the last generation call of a turn stops at its output token ceiling, the turn ends as truncated and the work is lost. Evidence: django__django-13964, 2026-09-21: 33 minutes, 41 rounds, no patch.

The ceiling of that call was the context window itself (262,144), not the 8,192 floor. The ACP agent gives `maxTokens: nil`, and `responseTokenCeiling(requested:contextTokens:)` gives `contextTokens` for that case. The peer session measured `context=262144` at session start. No ceiling hunt is needed.

## Do this

A ceiling stop returns from the generate call. It does not throw. Thus the session keeps its entries, and this case is simpler than ^9ddjkjm.

1. After an attempt returns, when its finish reason is the ceiling (`FinishReason` maxTokens, see `Session/FinishReason.swift`) and the measured context is at or over `triggerTokens`: compact with `performAutoCompaction`, emit `.compaction`, then run one continuation attempt in the same turn.
2. Use the same short continuation prompt as ^9ddjkjm ("the context was compacted, your last output was cut, continue the task").
3. Limit the continuations in one turn.
4. When the context is under the trigger, do not compact. A cut output with room left is a different problem, and a compaction does not help it.

## Acceptance

- A test with a scripted backend that stops one attempt at the ceiling while over the trigger: one compaction runs, one continuation attempt runs, the turn ends with a response and the caller sees one turn.
- The same script under the trigger: no compaction, the turn ends as truncated as today.

Requested by foundationmodelsacpagent-08. #compaction