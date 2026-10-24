---
comments:
- actor: wballard
  id: 01m5q5n6dwsw5vabnhw3yxt15b
  text: 'Done in the card-2 commit. Router now owns the mark and the error: SessionCallMark (Sources/FoundationModelsRouter/Session/SessionCallMark.swift, bound in the task-local wrapper submission(...) in place of ModelCallMark) and the public RoutedSessionError.inBandWaitForOwnSession(sessionID:). refuseInBandWaitForOwnSession() refuses only when the open mark names the waited session; the queue check and refuseWaitInsideOpenSubmission() are gone, and the GenerationQueueError alias is removed. Background runs: Extras'' BackgroundToolRunner runs the body, and this card may not change Extras, so Router cannot wrap the body or clear the mark there. The check instead knows a background run by its ambient ToolContext: the body runs with the completion token of its run, and that run is open on the run plane of the session; such a wait is not refused. After the call that started the run ended, the mark (one shared reference) is closed, so a later wait is not refused either. Removing the run-plane check makes NestedGenerationReentryTests ''a declared background body asks the session that started it for an answer'' fail, so it is load-bearing. The summarizer call binds no mark now (its backend has no tools). Tests: own-session refusal, background run after its answer ended, and the task-local reads (ToolContext, SessionOwnWork, SessionCallMark, SubagentQuestionHost) are in ToolBodyHoldsNoLockTests; the two same-model waits were restated as answered in card ^qhgfajc; NestedGenerationReentryTests now expects RoutedSessionError; GenerationQueuePublicSurfaceTests became InBandWaitRefusalPublicSurfaceTests.'
  timestamp: 2026-10-24T14:39:53.788756+00:00
depends_on:
- 01M5PSSK1HD9DVYPW7WQHGFAJC
position_column: done
position_ordinal: ffffffffc380
title: Refuse an in-band wait only for the same session, with a Router-owned mark
---
## What

Remove the queue re-entry refusal from Router. Keep the one real rule, with a Router-owned mark and error: a tool must not wait in-band for its OWN session. That session's pump runs one answer at a time, so it cannot start its next answer while the tool runs inside the current one.

Today Router uses Extras' `ModelCallMark`, `SubmissionTarget` and `GenerationQueueError.waitInsideOpenSubmission` for two checks: the queue check (a wait for any session on the same model is refused, `RoutedSessionActorGeneration.swift:242-247`) and the same-session check. The Extras task "Delete the per-model generation queue and ModelCallMark, after Router stops using them" (01M5PSQ2YCRA2BW4ZMXMB9Y6QY) deletes those types, and it needs this task first.

- [ ] Add a Router task-local, for example `SessionCallMark(sessionID:)` in `Sources/FoundationModelsRouter/Session/`. Bind it in the task-local wrapper `Self.submission(...)` (`RoutedSessionActorAnswerExecution.swift` 946-977) in place of `ModelCallMark`.
- [ ] Add a Router-owned error for the same-session wait, for example `RoutedSessionError.inBandWaitForOwnSession(sessionID:)`. Keep the present message text if possible.
- [ ] `RoutedSessionActorGeneration.swift:232-247`: refuse an in-band wait only when the mark names the session that is waited for. Remove `refuseWaitInsideOpenSubmission()` and the queue check.
- [ ] **Background runs.** Today Extras `withBackgroundRunMark` (`BackgroundToolRunner.swift:72, 169`) gives a background body a closed mark. Then a background run may wait for its own session after the call that started it has ended. Extras cannot see the Router-owned mark, so give the background path a way to clear `SessionCallMark`. For example, Router wraps the background body it hands to the run plane, or Extras gives a hook. Say which in the commit.
- [ ] Remove each use of `ModelCallMark`, `SubmissionTarget`, `isOpenModelCall(of:)` and `GenerationQueueError`: `RoutedSessionActorAnswerExecution.swift:761, 838`, `RoutedSessionActorCompaction.swift:96, 457`, and `RoutedSessionActorGeneration.swift:244`.

## Acceptance Criteria

- [ ] **A tool that uses the same model completes.** An in-band tool body that runs or waits for an other routed session on the same model gets its answer: no refusal and no deadlock.
- [ ] An in-band tool body that waits for its own session is refused with the new error.
- [ ] A background run that waits for its own session after the starting call ended is not refused.
- [ ] `rg -n 'ModelCallMark|SubmissionTarget|refuseWaitInsideOpenSubmission|isOpenModelCall|GenerationQueueError' Sources Tests` finds nothing in Router.
- [ ] Each task-local of the wrapper still has its value in a tool body (a test reads `ToolContext` and `SessionOwnWork`).

## Tests

- [ ] Restate `Tests/FoundationModelsRouterTests/GenerationQueueSubmissionTests.swift`: `anInBandWaitForASessionOnTheSameModelIsRefused` becomes "...is answered", and `anInBandWaitForABusySessionOnTheSameModelIsRefused` becomes "...is answered after its turn". Add the own-session refusal and the background-run case.
- [ ] Restate `NestedGenerationReentryTests` and `HumanWaitGateTests` as necessary.
- [ ] `swift test` in FoundationModelsRouter: all tests pass, with no new warnings.

## Workflow

- Use `/tdd`: write the failing tests first, then implement until they pass.
- After the push: tell the FoundationModelsMultitool session to remove its test uses of `GenerationQueueError.waitInsideOpenSubmission` (`SearchToolsToolTests.swift:366`, `SampleSnippetTests.swift:224`, `ScenarioGrading.swift`). Then tell the user that the Extras delete task can start.