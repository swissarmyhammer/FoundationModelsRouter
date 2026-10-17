---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5476a8z92b0vezzcmebywf9
  text: |-
    ### Decisions of the coordinating session (swissarmyhammer-96), 2026-10-17
    - Group 1 (8 race places): first find an event that comes AFTER the expected state in every run (for example the feed end after a close, or the session close that the test does itself). If such an event exists, end the wait on it. If not, keep the wait and add a one-line comment that names the race. Add no new production hook.
    - Group 2 (quiet states): keep each wait. At each place, add a one-line comment that says which failure would hang there and why no event exists.
    - Group 3: (a) ManualRunClock.waitForSleepers: the test-only extension of card 3/6 is sufficient now. A cancel handler in Extras is a later Extras item. (b) AsyncSemaphore: use waitUnlessCancelled(), as card 5/6 says. Bring a site to the coordinating session only if that cannot fix it.
    - Group 4: (a) Router-only tests: Router has no close(), so the close part is out of scope. If such a test makes a temporary directory, it must also remove it on a throw. A separate card at the end of the chain does this. (b) Backend-only tests: in scope only where the backend has an end call or a cancel call that the test can use in a defer. Else out of scope, with a comment at the place. (c) Partial closes: a separate card at the end of the chain audits them: each session that a test makes (root and fork) closes, also on a throw.
  timestamp: 2026-10-17T06:01:09.151502+00:00
- actor: claude-code
  id: 01m550bte3nrpr770tw2fxxajs
  text: |-
    ### Implementation notes (implement)
    - No b1-b9 or c1 card had fixed a site of this card. Each Group 1 site was still in its old form, at a later line.
    - New shared helpers (test code only, no production change):
      - `ChangeSignal.wait(until:endingWhenWorkEnds:sourceLocation:)` in Tests/FoundationModelsRouterTests/Helpers/ChangeSignalWait.swift. It runs `awaitIdle()` in a task, cancels that task in a `defer`, and uses `wait(until:endingOnEndOf:)`, so it reads the state again after the end. `MailQueueFixtures.waitForPrompts(_:on:endingWhenWorkEnds:)` now calls it, so the two do not duplicate the pattern.
      - `SessionEventLog.wait(until:endingOnEndOf:sourceLocation:)` in Helpers/SessionEventLog.swift: a log wait that also ends on the end of its drain task (feed end).
      - Two new tests in TaskEndEventWaitTests for the log wait (one `withKnownIssue` failure case, one pass case). The endingWhenWorkEnds helper is covered by the existing PromptWaitTests case through MailQueueFixtures.
    - Event after the state, per Group 1 site:
      - SubmissionBoundaryToolTests, PerCallMountSessionTests, SessionOutboxToolWiringTests: the end of the work of the session (`awaitIdle()`). A staged terminal of a settled run, user-type mail, an answer that resumes a run and an open run are all work, so the work ends only after the expected prompts or calls.
      - QueuedPassStallWatchTests: the test closes the holding session after both answers returned; the feed end after the close ends the drain.
      - NoOpToolCallStopTests: the test waits for `awaitIdle()` (after the delivery answer), then closes the session; the feed end ends the drain. A close before idle would sweep the delivery, so the close must come after the idle wait.
      - MountedRunAttachmentCarrierTests: the open record of the gated call can come before the report, so no event comes after the report in every run. Kept with a race comment.
      - SessionChokepointTests: the release of the session can come after a drain of the admission queue. Kept with a race comment.
      - MountedRunSweptTerminalTests 171: the close ends only after the gate opens, and the test must read the sink first. 211: the own terminal can come after the end of the close. Both kept with race comments.
    - Close of a closed session is safe: `closeAndAwaitTheEnd()` finds each step done on a second run.
    - Group 4 (b): `LanguageModelSessionBackend` has no end call and no cancel call, so the three backend-only suites get one comment each and no close.
  timestamp: 2026-10-17T13:21:03.939134+00:00
- actor: claude-code
  id: 01m550c36nzsp5834374pn0x9c
  text: |-
    ### implement — changed
    - evidence: 23 test files changed, no production code. Helpers: ChangeSignalWait.swift, SessionEventLog.swift, MailQueueFixtures.swift, SessionPlumbingAccess.swift, RepeatingReasoningModel.swift. Suites: SubmissionBoundaryToolTests, PerCallMountSessionTests, QueuedPassStallWatchTests, NoOpToolCallStopTests, SessionOutboxToolWiringTests (waits changed); MountedRunAttachmentCarrierTests, SessionChokepointTests, MountedRunSweptTerminalTests (race comments); SubagentQuestionRelayTests, SessionWorkEventTests, SessionCloseFromOwnWorkTests, SessionIdleWaitTests, SessionDrainTests, AnswerCancellationFixtures (quiet-state comments); GenerationQueueTests, TranscriptUpdatesToolLoopTests, LanguageModelSessionBackendTests (backend-only comments); TaskEndEventWaitTests (2 new tests). Targeted run `swift test --filter 'FoundationModelsRouterTests\.(TaskEndEventWaitTests|PromptWaitTests)'`: 13 tests in 2 suites passed, 7 known issues (all intended). Full suite `swift test` one time: "Test run with 1834 tests in 225 suites passed after 5.228 seconds with 9 known issues" (all are intended withKnownIssue tests, one of them new), then 26 tests in 14 suites passed and 19 tests in 3 suites passed; XCTest 0 tests. No compiler warning (only the SwiftPM mlx line "missing creator for mutated node"). IntegrationTests compiles no changed file, so it was not built. Not committed.
    - next: /review
  timestamp: 2026-10-17T13:21:12.917236+00:00
- actor: claude-code
  id: 01m550ct3zwrgss2pnhcxr9j81
  text: 'Correction to the step record above: the full suite ran two times, not one time. The first run (1832 tests in 225 suites passed, 8 known issues) came before the code changed again: the change of `MailQueueFixtures.waitForPrompts(_:on:endingWhenWorkEnds:)` to the shared helper and the 2 new TaskEndEventWaitTests tests. The second run, after that change, is the result that the record gives (1834 tests, 9 known issues).'
  timestamp: 2026-10-17T13:21:36.383902+00:00
- actor: claude-code
  id: 01m550xfwym5bcjhfx9pft1mkq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit c733c35e). 0 findings, 0 confirmed, 0 refuted. 28 validator runs, 0 failed, 0 skipped. 23 files reviewed. 6 .kanban files not reviewed because of .reviewignore.
    - next: The task is in done. No open findings.
  timestamp: 2026-10-17T13:30:42.974538+00:00
- actor: claude-code
  id: 01m550y3z4eq137js722sq9ptb
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 23 test files
    - test: green — full swift test after the last helper change: 1834 tests in 225 suites + 26 + 19 passed (the full suite ran two times on this card)
    - commit: c733c35e
    - review: clean — 0 findings, 23 files reviewed
  timestamp: 2026-10-17T13:31:03.524188+00:00
depends_on:
- 01M5473QWCC106G7P89CJ4FD37
position_column: done
position_ordinal: ffffffff8d80
title: 'T1 follow-up c2: decision for swissarmyhammer-96 on the T1 places that stay (race, quiet state, production hook)'
---
Source: task ^dbr1dqy (T1 audit, done), comment "kinds of waits checked and left", and the check of 2026-10-17. This card does not change code first. It lists the places where no fix under the rule is known, each with its reason, so that the coordinating session (swissarmyhammer-96) decides: leave the place (with a comment in the test), or approve a change.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

Group 1: a change can add a race (the audit left these; the failure event can come before the state also in a passing run, so a wait that ends on it fails a good run). Line numbers are from 2026-10-17.
- [x] SubmissionBoundaryToolTests.swift:298 `log.changes.wait(untilAtLeast: expected.count, ...)`. Result: the wait also ends when the work of the session ends (`awaitIdle()`); the staged terminal is work until its submission ends.
- [x] PerCallMountSessionTests.swift:146 `promptsAfterThePumpStops(atLeast:)` (callers 224, 276). Result: the wait also ends when the work of the session ends.
- [x] QueuedPassStallWatchTests.swift:150 `holdingLog.wait(until: { $0.contains(where: \.isAnswerEnd) })`. Result: the test closes the holding session, and the wait also ends on the end of the drain (feed end after the close).
- [x] NoOpToolCallStopTests.swift:81 `events.wait(until: { ... isAnswerEnd })` (runSettled comes first also in a pass). Result: the test waits for `awaitIdle()`, closes the session, and the wait also ends on the end of the drain.
- [x] MountedRunAttachmentCarrierTests.swift:144 the first `next()` loop. Result: kept, with a comment that names the race (the gated call can open before the report).
- [x] SessionChokepointTests.swift:298 `waitForEvictions` (caller 521). Result: kept, with a comment that names the race (the last release can come after a drain of the admissions).
- [x] SessionOutboxToolWiringTests.swift:1546, 1552 the answer-prompt waits. Result: both waits also end when the work of the session ends.
- [x] MountedRunSweptTerminalTests.swift:171 (and 211) the own-terminal wait. Result: both kept, each with a comment that names the race.
For each: the decision is "leave, with a comment that names the race", or a named other event.

Group 2: no failure event (a quiet state). Gates of the test hold all other work, or the missing event has nothing after it. The audit left these, and no fix is possible under the rule. Decision: confirm "leave", and say if each place needs a comment in the test.
- [x] SubagentQuestionRelayTests root reads for a question or an end that the relay does not send (root run held on its gate). Result: comments at `outputsThroughQuestion`, the completion read and the end read.
- [x] `outputs(throughNextWorkEnd:)` and `awaitIdle()` where the named failure is "the session stays work". Result: comment in `outputs(throughNextWorkEnd:)`, and at each `awaitIdle()` wait that can hang (SessionIdleWaitTests, SessionWorkEventTests, SessionDrainTests, SubagentQuestionRelayTests).
- [x] `isIdleOnceThePumpEnds` / a pump that never ends. Result: comment in the helper.
- [x] SessionCloseFromOwnWorkTests `closeReturned` (the failure is the hang itself). Result: comment at both waits.
- [x] Hold gates that wait only for a cancel (`.untilStopped`, `awaitCancelledUnwind`). Result: comments in `waitForStop()`, at the `suspended` gate and in `awaitCancelledUnwind`.

Group 3: a full fix needs a production change only for a test hook (not permitted without approval).
- [x] `ManualRunClock.waitForSleepers(atLeast:)` in ../FoundationModelsExtras/Sources/FoundationModelsExtras/Hosting/RunClock.swift:177 has no cancel handler. Card "T1 follow-up 3/6" uses a test-only extension; its inner task stays suspended until the next clock change. Decision: is that sufficient, or does RunClock get a cancel-aware wait? Result: card ^404vfsz is done; it changed all its sites and left none. Nothing is left for this card.
- [x] `AsyncSemaphore.wait()` (Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:147) does not end on a cancel. Card "T1 follow-up 5/6" uses the existing `waitUnlessCancelled()`. Decision only if that card reports a site that it cannot fix. Result: card ^3yhsh6e is done; it reports no site for the coordinating session. Nothing is left for this card.

Group 4: scope questions from the check of the "never close" group.
- [x] Router-only tests (a Router and a resolve, no session): `Router` has no `close()`. Suites: ResolutionProgressPublicSurfaceTests (Tests/FoundationModelsRouterPublicSurfaceTests), EmbedTracingTests, ExtrasPoolResolveTests, OwningProfileTests, ProfileLifecycleTests, ResolveCancellationTests, ResolveTracingTests, ToolSharedProfileTests, and router-only tests in DistinctGenerationSlotsTests, GuidedShapesTests, PromptCacheBudgetTests, ResolveTests and 14 session suites. Decision: out of scope (no close exists), or remove the temp directory on a throw? Result: the separate card ^1b1zmq8 does the temporary directories.
- [x] Backend-only tests (`container.makeSession` gives a LanguageModelSessionBackend, not a RoutedSession): GenerationQueueTests, TranscriptUpdatesToolLoopTests (runs concurrent tool loops), LanguageModelSessionBackendTests. Decision: in scope or not? Result: `LanguageModelSessionBackend` has no end call and no cancel call, so out of scope; one comment in each of the three suites.
- [x] Partial closes: the check counts a test as closed when it closes any session, also when it makes a root and a fork and closes only one, and also when the close is only in a `catch`. Decision: audit those too (one more card), or not. Result: the separate c4 card after ^1b1zmq8 does this audit.

- [x] Write the decision for each item as a comment on this card. For each "change" decision, add a card with tag `t1-followup`. #t1-followup