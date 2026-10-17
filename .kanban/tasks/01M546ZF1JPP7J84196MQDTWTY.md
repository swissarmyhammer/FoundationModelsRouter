---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m54kd6xe139q7hcegn46jg22
  text: 'Picked up. Research: the prevailing form is `defer { try? FileManager.default.removeItem(at: fixture.directory) }` and then `defer { await fixture.session.close() }`, so the close runs first. A local `runAnswer` helper that returns an open session uses `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` with `{ await fixture.session.close() }`. A gated tool (`GatedMarkerTool`) has no `RunLatch`, so `SessionFixtureLifecycle.close(_:opening:)` does not fit; its defer opens the gate and then closes. Discovery: the `files` edit op with `replace_all: true` replaced only 1 match, so each place needs its own edit with unique context. Done so far: IdenticalToolCallLimitTests, ToolCallFailureAnswerTests, ToolCallRepetitionStopTests, ToolCallRunJoinTests, ToolContextMountSinkPublicSurfaceTests, ToolInvocationLivenessTests, ToolOutputCappingTests, ToolOutputFeedbackTests, ToolOutputProtectionSessionTests, RejectedToolCallRetryTests, ScriptedToolAnswerComparisonTests, SubmissionBoundaryToolTests, SubmissionBoundaryToolPublicSurfaceTests.'
  timestamp: 2026-10-17T09:34:37.998035+00:00
- actor: claude-code
  id: 01m54kv08qb4zsymgjjt6j8ym6
  text: |-
    Implementation landed in 17 test files. Notes for the next agent:
    - Each listed test closes each session that it makes (root, fork, restored) in a `defer` right after the make. The recorded session of a restore test stays open through the restore and closes after the restored session.
    - Held work: a `RunLatch` gate opens through `SessionFixtureLifecycle.close(_:opening:)` before the close (PerCallMountSessionTests, MountedRunAttachmentCarrierTests, SessionOutboxToolWiringTests). In `forkBackgroundRunLivesInForkRunPlane` the held run is on the fork, so the fork closes with the gate. `GatedMarkerTool` (ToolInvocationLivenessTests) has no `RunLatch`, so its defer opens the gate and then closes.
    - Helpers that return an open session (`runAnswer`, `makeHarness`, `makeSession`, `makeCancellationObservingSession`, `makeBackgroundingSession`) now close the session and remove the directory when a later step throws, through `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)`. Helpers that do not return the session (`driveAnswer`, `mountingAnswerEvents`, `expectInBandCallReportsItsAttachments`, `makeRespondRun`, `makeStreamRun`, `assert*ComposesBindOnly*`) close it in their own defer, after they read their values.
    - Existing answer Tasks in the changed tests are cancelled in a `defer`, before the close.
    - Each close runs after the checks, so no close adds an event that a check counts, and no wait ends earlier than before.
    - Filtered run: `swift test --filter 'FoundationModelsRouterTests\.(<17 suites>)/'`: 125 tests in 17 suites passed.
    - Full run (`swift test`, one time): 1827 tests in 224 suites passed with 6 known issues (the `withKnownIssue` cases of RealModelHarness, PromptWaitTests, TaskEndEventWaitTests and ManualRunClockWaitTests, not changed); public surface: 26 tests in 14 suites passed; 19 tests in 3 suites passed; XCTest: 0 tests. No compiler warning; the one build warning is the known mlx-swift bundle warning. IntegrationTests compiles no changed file, so it was not built.

    ### implement — changed
    - evidence: 17 files under Tests/FoundationModelsRouterTests/ (IdenticalToolCallLimitTests, ToolCallFailureAnswerTests, ToolCallRepetitionStopTests, ToolCallRunJoinTests, ToolContextMountSinkPublicSurfaceTests, ToolInvocationLivenessTests, ToolOutputCappingTests, ToolOutputFeedbackTests, ToolOutputProtectionSessionTests, RejectedToolCallRetryTests, ScriptedToolAnswerComparisonTests, PerCallMountSessionTests, MountedRunAttachmentCarrierTests, RoutedSessionToolContextBindingTests, SessionOutboxToolWiringTests, SubmissionBoundaryToolTests, SubmissionBoundaryToolPublicSurfaceTests); `swift test`: 1827 tests in 224 suites passed (6 known issues), 26 in 14 suites passed, 19 in 3 suites passed
    - next: review
  timestamp: 2026-10-17T09:42:09.943787+00:00
- actor: claude-code
  id: 01m54m7hb7084knhf39nyr0552
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 2a876eaa). 3 findings, 3 confirmed, 0 refuted. Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:361, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift:201, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift:483. The rule that drops findings that ask to refactor tests that already existed does not apply: each finding is on lines that this commit added or wrote again.
    - next: implement the 3 open items in the "Review Findings (2026-10-17 04:43)" section. The task stays in review.
  timestamp: 2026-10-17T09:49:00.647045+00:00
- actor: claude-code
  id: 01m54m8mfsdcc5fdgkgck8qf74
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 17 test files
    - test: green — the one full swift test run of the implement step: 1827 tests in 224 suites + 26 + 19 passed
    - commit: 2a876eaa
    - review: findings — RoutedSessionToolContextBindingTests.swift:361, ToolInvocationLivenessTests.swift:201, ToolInvocationLivenessTests.swift:483
  timestamp: 2026-10-17T09:49:36.633641+00:00
- actor: claude-code
  id: 01m54mfmhwty15dpc22xqrj1vh
  text: |-
    Review findings (2026-10-17 04:43) done:
    - RoutedSessionToolContextBindingTests: the new `makeVendedSession(over:vend:vendedBackend:)` is now the one setup. It makes the temp directory, builds the router over the container, resolves the profile, makes the session, and reads the vended backend, with `removingDirectoryOnThrow` on each step that can throw. `makeSession(grammar:)` gives it a `vend` closure that holds the grammar branch. `makeCancellationObservingSession()` gives it `{ model in model.makeSession() }`. `Backend` is generic and `Sendable`, so the result can go to the `@MainActor` tests.
    - ToolInvocationLivenessTests: the new `releaseAndClose(_:_:)` opens the gate of the `GatedMarkerTool` and then closes the session. The two copied defers now call `defer { await Self.releaseAndClose(slowTool, fixture.session) }`. Same cause in the whole file: `backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` had a third inline open-then-close defer, on a `RunLatch`. It now calls the shared `SessionFixtureLifecycle.close(fixture.session, opening: [gate])`.
    - Note: the kanban `move task` and `update task` ops return the full board (about 166 000 characters), so the tool saved each reply to a file. I checked the result in the task `.md` file, not in the reply.
    - Filtered run: `swift test --filter 'FoundationModelsRouterTests\.(RoutedSessionToolContextBindingTests|ToolInvocationLivenessTests)/'`: 26 tests in 2 suites passed.
    - Full run (`swift test`, one time): 1827 tests in 224 suites passed with 6 known issues (the `withKnownIssue` cases, not changed); 26 tests in 14 suites passed; 19 tests in 3 suites passed; XCTest: 0 tests. The one build warning is the known mlx-swift bundle warning. No compiler warning.

    ### implement — changed
    - evidence: 2 files: Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift; `swift test`: 1827 tests in 224 suites passed (6 known issues), 26 in 14 suites passed, 19 in 3 suites passed
    - next: review
  timestamp: 2026-10-17T09:53:26.076122+00:00
depends_on:
- 01M546YNM74MV9HRDSA7CNP2A0
position_column: doing
position_ordinal: '80'
title: 'T1 follow-up b4: tool output, tool call and mount suites close each session, also when the body throws'
---
Source: task ^dbr1dqy (T1 audit, done). The audit left "tests that never close their session or router at all (about 60 suites)" out of scope. A new check on 2026-10-17 found 107 suites with tests that make a RoutedSession and never close it. `Router` has no `close()`; only `RoutedSession` does, so this group is about sessions only. This card has the tool output, tool call and mount suites.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

How to close (use the forms that T1 added):
- Put `defer { await <session>.close() }` right after the session is made, for each session the test makes (root, fork). With gates, use `SessionFixtureLifecycle.close(_:opening:)` (Helpers/SessionFixtureLifecycle.swift:83). `close()` is idempotent.
- `ScriptedSessionFixture`, `RejectingSessionFixture` and local `runAnswer` / `makeFixture` / `makeHarness` helpers do not close. Give the fixture an `end()` (close, then remove the directory), or close inside the helper; use `RouterTestFixtures.removingDirectoryOnThrow(_:alsoOnThrow:_:)` (Helpers/RouterTestFixtures.swift:156) for the throw path.
- A close sweeps open background runs and journals their terminals. In mount and outbox tests, check that the close does not add events that a later check counts.
- After a close, a test that waits on a feed now ends on the feed end. Check that no test now passes only because a wait ends early.

Suites (file under Tests/FoundationModelsRouterTests/; the tests that never close):
- [x] IdenticalToolCallLimitTests, IdenticalToolCallLimitTests.swift: all 4 (local runAnswer; the 2 other suites in the file are value-only).
- [x] ToolCallFailureAnswerTests, ToolCallFailureAnswerTests.swift: all 4 (ScriptedSessionFixture.make).
- [x] ToolCallRepetitionStopTests, ToolCallRepetitionStopTests.swift: all 2 (local runAnswer).
- [x] ToolCallRunJoinTests, ToolCallRunJoinTests.swift: 2 of 8 (invocationEventsCarryTheToolCallIdOfTheirRun, twoRunsOfOneToolJoinTheirOwnCalls).
- [x] ToolContextMountSinkPublicSurfaceTests, ToolContextMountSinkPublicSurfaceTests.swift: all 4 (local driveAnswer).
- [x] ToolInvocationLivenessTests, ToolInvocationLivenessTests.swift: 7 of 20 (liveInvocationEventArrivesWhileTheToolStillRuns, invocationRecordsAreDeliveryOnlyAndChangeNoRecording, reportPostedDuringTheSubmissionArrivesOnTheAnswerStreamAfterTheCloseRecord, runToCompletionCallReportsItsAttachmentsOnTheAnswerStream, contextBindingToolCallReportsItsAttachmentsOnTheAnswerStream, callWithNoAttachmentsProducesNoReport, reportIsNeverStagedOrRecorded).
- [x] ToolOutputCappingTests, ToolOutputCappingTests.swift: 7 of 19 (makeSessionWithToolOutputLimitThreadsCappedTool, makeSessionWithNoToolOutputLimitLeavesToolUnwrapped, makeSessionWithNoBudgetLeavesToolUnwrapped, cappingComposesWithAmbientEventRoute, forkInheritsToolOutputLimitCapping, forkWithNoToolOutputLimitLeavesChildToolsUnwrapped, forkWithNoBudgetLeavesChildToolsUnwrapped).
- [x] ToolOutputFeedbackTests, ToolOutputFeedbackTests.swift: all 2.
- [x] ToolOutputProtectionSessionTests, ToolOutputProtectionSessionTests.swift: all 6.
- [x] RejectedToolCallRetryTests, RejectedToolCallRetryTests.swift: all 2 (RejectingSessionFixture.make).
- [x] ScriptedToolAnswerComparisonTests, ScriptedToolAnswerComparisonTests.swift: all 6 (local makeRespondRun / makeStreamRun).
- [x] PerCallMountSessionTests, PerCallMountSessionTests.swift: all 4 (local makeHarness).
- [x] MountedRunAttachmentCarrierTests, MountedRunAttachmentCarrierTests.swift: all 3 (local makeFixture / mountingAnswerEvents). Note: T1 listed "close on throw" for this file; the check found no close on the success path.
- [x] RoutedSessionToolContextBindingTests, RoutedSessionToolContextBindingTests.swift: all 6 (local makeCancellationObservingSession).
- [x] SessionOutboxToolWiringTests, SessionOutboxToolWiringTests.swift: all 29 (local makeBackgroundingSession / assert*ComposesBindOnly*).
- [x] SubmissionBoundaryToolTests, SubmissionBoundaryToolTests.swift: all 5.
- [x] SubmissionBoundaryToolPublicSurfaceTests, SubmissionBoundaryToolPublicSurfaceTests.swift: all 1 (ScriptedSessionFixture.make).
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup

## Review Findings (2026-10-17 04:43)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 17 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:361` `reuse/reuse` — makeCancellationObservingSession repeats the router, resolve, and backend-vend block of makeSession (lines 328-346): the temp directory, the router built over a StubModelLoader, the removingDirectoryOnThrow resolve, and the removingDirectoryOnThrow backend lookup. Only the container type and the session construction differ. Two copies of this setup diverge over time, and the directory-cleanup-on-throw rule must now be kept in step in both. Extract the shared setup into one helper that takes a container and returns the resolved profile, or the vended backend, for both makeSession and makeCancellationObservingSession to call. The grammar branch can stay in makeSession, which passes its session-making step in or calls the shared helper before it.
- [x] `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift:201` `duplication/duplication` — The six-line defer that opens the gate, then closes the session, is copied verbatim into a second test in the same file (line 483). Both copies carry the same comment and the same two statements. A later change to the close ordering, such as a missing gate open, would have to be made in both places. Move the gate-then-close into one helper, for example a static func that takes the GatedMarkerTool and the fixture session, and call it from both defers: `defer { await Self.releaseAndClose(slowTool, fixture.session) }`.
- [x] `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift:483` `duplication/duplication` — This defer repeats the gate-open-then-close block at line 201 verbatim. The two copies must stay in step, and the same fix belongs at both sites. Replace both defers with one shared helper that opens the gate and closes the session, and call it from each test.