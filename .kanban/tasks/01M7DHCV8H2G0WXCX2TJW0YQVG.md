---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7fgxm8pstm956cs793j1312
  text: 'Research: WatchStopReport.continuationPrompt / finalPassPrompt (RoutedSessionActorRepetitionWatch.swift) pick the recovery and final-pass prompts; RoutedSessionActor.recover and runFinalPass send them. Fix: they become continuationPrompt(hasTools:) / finalPassPrompt(hasTools:), fed by a new RoutedSessionActor.hasDeclaredTools (= !declaredToolNames.isEmpty, reusing RejectedToolCallRetry.swift''s declaredToolNames). Tools wording kept under the same static names (reasoningStopContinuationPrompt, repetitionStopActRequest, repetitionStopContinuationPrompt, finalPassPrompt). New no-tools prompts: answerOnlyRequest (also the whole reasoning-stop recovery prompt), repetitionStopAnswerPrompt (= new repetitionStopNotice + answerOnlyRequest), finalPassAnswerPrompt. A repeated-tool-call stop keeps the tool notice (a tool was called, so the session has tools). Discovery: six existing hermetic tests ran toolless sessions and asserted the tools wording (RepetitionStopTests x2, ReasoningTokenLimitTests x2, ReasoningStopRecoveryTests x2); updated to the no-tools prompts. Integration test StandardModelReasoningStopRecoveryIntegrationTests mounts ReadFileTool, so its compare against reasoningStopContinuationPrompt stays right unchanged. Env note: `swift build --package-path IntegrationTests` fails in a worktree because the root package identity comes from the dir name (agent-...), not FoundationModelsRouter; built from an rsync copy under a dir named FoundationModelsRouter instead.'
  timestamp: 2026-11-15T11:54:12.630532+00:00
- actor: claude-code
  id: 01m7fh241knh3825kwh8nvzqas
  text: |-
    ### implement — changed
    - evidence: RED: new RecoveryPromptToolsTests, 3 no-tools tests failed, 3 tools tests passed. GREEN: 6/6. `swift build --build-tests` clean (no warnings from repo sources); full `swift test`: 2722 tests in 321 suites passed, plus 42 and 19 in the other runners, 0 failures. `swift build --package-path IntegrationTests --build-tests`: Build complete (from a copy under a dir named FoundationModelsRouter; only dependency warnings, libgit2 C++ interop / cache lock). No real-model integration tests run. Files: Sources/FoundationModelsRouter/Session/{RoutedSessionActorRepetitionWatch,RoutedSessionActorReasoningStop,RepetitionDetection}.swift; Tests/FoundationModelsRouterTests/{RecoveryPromptToolsTests (new),IdenticalToolCallLimitTests,ReasoningStopRecoveryTests,ReasoningTokenLimitTests,RepetitionStopTests,Helpers/RepeatingReasoningModel,Helpers/CeilingStopCompactionModel}.swift
    - next: /review
  timestamp: 2026-11-15T11:56:39.859937+00:00
- actor: claude-code
  id: 01m7fh67dh6rdptq27cnphj2de
  text: |-
    ### commit — changed
    - evidence: 4596ac10 fix(session): ask only for the answer when a session has no tools (^jw0yqvg), cherry-picked from 55836517 onto main. On main: swift test 2731 + 42 + 19 green, and the IntegrationTests build-tests pass.
    - next: none
  timestamp: 2026-11-15T11:58:54.385327+00:00
position_column: done
position_ordinal: ffffffffff9a80
title: Recovery prompts name tool calls in sessions with no tools
---
## Problem

`RoutedSessionActor.reasoningStopContinuationPrompt` (`Session/RoutedSessionActorReasoningStop.swift`), `repetitionStopActRequest` and `finalPassPrompt` (`Session/RoutedSessionActorRepetitionWatch.swift`) tell the model "one tool call … or your final answer" / "make it now with one tool call". A session with no tools gets that text too, and the model is told to call a tool it does not have.

Found while working ^qmewzw0, whose card recorded it as a separate finding and asked to leave the wording alone there.

## Done when

- A session with no tools gets recovery and final-pass prompts that ask only for the final answer; a session with tools keeps today's wording.
- Hermetic unit tests cover both; `swift build --build-tests` and `swift test` are green.