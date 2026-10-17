---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m548j8vsh3xnbke1pe7q1j7q
  text: |-
    Research (implement step):
    - Form chosen: `changes.wait(until:endingOn:)` with `RecordedWaitResult.recordingEnd(of:reportingTo: changes)`, as `ElicitationPostings.waitForPosts(_:endingOnEndOf:)` does. The wait reads the prompt count again after the end, so a prompt that came before the end passes also when the end signal comes first.
    - Event for a site with an answer task (`Task { respond }`): the end of that task. The held call keeps the task open in a test that passes.
    - Event for a site with no answer task (a send, a `mail(_:)`, or a post of run mail): the session becomes idle (`becomesIdle()`). A send puts the user mail in the queue before it returns, and a post of a terminal or message event wakes the pump before it returns (`SessionOutbox.post(event:)` awaits `mailArrived()`). So the session is not idle until a pump took the mail and ended, and the pump ends only after its submission called the backend.
    - Not usable: `awaitTerminal(of:)` in a task. A cancel of that task calls `cancel(id)`, which sends a signal and its events, and a task that is not cancelled stays in the hub and changes `hub.waiterCount` (MailSubscriptionTests `awaitTerminalOfMail` waits for `waiterCount == 1` after `startHeldAnswer`). `pumpEnds()` is not usable after a send: the pump starts in a helper task, so no pump can run yet when the wait starts.
    - Found: `becomesIdle()` reads `isPumpRunning` first and the queue second. A pump can start and take the mail between the two reads, so the check can see an idle session while the pump runs. Reading the queue first removes this: a pump that took the mail runs until it ends.
  timestamp: 2026-10-17T06:25:09.497963+00:00
- actor: claude-code
  id: 01m54941vdwemp8r7gcw35wzct
  text: |-
    Implementation landed (not committed). Each site, its failure, and the event that also comes in that failure:

    New helpers (test helpers only, no production change):
    - `PromptCountingBackend.waitForPrompts(_:endingOnEndOf:sourceLocation:)` (MailQueueFixtures.swift): `changes.wait(until:endingOn:)` with `RecordedWaitResult.recordingEnd(of:reportingTo: changes)`. It reads the count again after the end.
    - `MailQueueFixtures.waitForPrompts(_:on:endingWhenIdle:sourceLocation:)`: the same member, with a task that ends when `becomesIdle()` holds. The task is cancelled after the wait, so no waiter stays on the idle signal.
    - The old `waitForPrompts(_:)` has no caller now, so I removed it.
    - `startHeldAnswer` now uses the idle form and takes `sourceLocation`.
    - `becomesIdle()` (SessionPlumbingAccess.swift) now reads the queue before the pump. With the old order, a pump could start and take the mail between the two reads, and the check then saw an idle session while the pump ran.

    Sites with an answer task (failure: the submission ends before it calls the backend; event: the end of the answer task):
    - SessionMessagePumpTests: `cancelOfAWaitingMessageWithdrawsIt`, `aRespondDuringASubmission...`, `aContinuationCarriesTheWaitingMessages`, `mailDuringASubmission...` (first wait), `cancelAllCancelsCallerMessages...` -> `endingOnEndOf: first`.
    - RunMessageDeliveryTests `aMessageWhileAnAnswerRuns...` (first wait) -> `endingOnEndOf: firstAnswer`.
    - SubmissionAnswerEventTests `aRespondWhoseCallerCancels...` -> `endingOnEndOf: run`.

    Sites with a send of a held answer (failure: the held answer never calls the backend; event: the session becomes idle) -> `MailQueueFixtures.startHeldAnswer`:
    - Helpers/MailQueueFixtures.swift `startHeldAnswer` itself.
    - MailTranscriptTests: 4 sites. OriginAndTerminalEventTests: 5 sites. SubmissionAnswerEventTests: 3 sites. SessionMessagePumpTests `cancelOfAMessageInARunningSubmissionDoesNotStopIt`.

    Sites with no answer task (failure: the mail or the post starts no submission that calls the backend; event: the session becomes idle) -> `MailQueueFixtures.waitForPrompts(_:on:endingWhenIdle:)`:
    - SessionMessagePumpTests: `startMailOnlyAnswer`, `aSendOnAnIdleSession...` (answer not held), `mailDuringASubmission...` (second wait), `aFailedDeliveryPutsItsMailBack...`.
    - RunMessageDeliveryTests: `aMessageOfAnOpenRunStartsAnAnswer`, `aLaterTerminalStartsItsOwnAnswer` (2 waits), `aMessageWhileAnAnswerRuns...` (second wait).
    - MailSubscriptionTests `mailRefusesAnIDOfTheOpenAnswer` (mail(_:) puts the mail in the queue before it returns).

    Quiet state that stays (decision group 2): when the mail never wakes a pump (no pump starts, the queue keeps the mail), no event comes, and each of these waits hangs. The session holds the mail and nothing ends. No site was left without an event.

    New tests: PromptWaitTests.swift (2 tests, both record a known issue at the call site and return). RED: compile error (member missing). GREEN: 2 tests in 1 suite passed with 2 known issues.
  timestamp: 2026-10-17T06:34:52.141050+00:00
- actor: claude-code
  id: 01m54990qkjhk9kxqxdj2h6acp
  text: |-
    ### implement — changed
    - evidence: `swift test` one full run, exit 0: "Test run with 1817 tests in 221 suites passed after 4.714 seconds with 3 known issues" (2 known issues are the new PromptWaitTests, 1 is the RealModelHarness embedding-slot test from before), plus "26 tests in 14 suites passed" and "19 tests in 3 suites passed"; XCTest: 0 tests. After a doc-comment edit, `swift build --build-tests` exit 0. The only build warning is SwiftPM "missing creator for mutated node" for mlx-swift_Cmlx.bundle (build graph, not a source file). IntegrationTests compiles none of the changed files, so I did not build it. Files: Tests/FoundationModelsRouterTests/Helpers/MailQueueFixtures.swift, Helpers/SessionPlumbingAccess.swift, PromptWaitTests.swift (new), MailSubscriptionTests.swift, MailTranscriptTests.swift, OriginAndTerminalEventTests.swift, RunMessageDeliveryTests.swift, SessionMessagePumpTests.swift, SubmissionAnswerEventTests.swift. No production code changed. Not committed.
    - next: /review
  timestamp: 2026-10-17T06:37:34.835873+00:00
- actor: claude-code
  id: 01m549j0dwy32r7bbxb5423kd0
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 2fda24ac). 9 files reviewed, 4 .kanban files not reviewed because of .reviewignore. Counts: findings 0, confirmed 0, refuted 0, attempted 14, failed 0, skipped 0. The task has no prior Review Findings sections.
    - next: The task is in done. Continue to the next task that this task blocks (^404vfsz).
  timestamp: 2026-10-17T06:42:29.436429+00:00
- actor: claude-code
  id: 01m549jsf0y6j4cngh5by974qr
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 9 test files
    - test: green — the one full swift test run of the implement step: 1817 tests in 221 suites + 26 + 19 passed, exit 0
    - commit: 2fda24ac
    - review: clean — 0 findings, 9 files reviewed
  timestamp: 2026-10-17T06:42:55.072721+00:00
depends_on:
- 01M546C19377FP3SF7YFPZCDT3
position_column: done
position_ordinal: fffffffc80
title: 'T1 follow-up 2/6: waitForPrompts of a prompt-counting backend also ends on the pump end or the answer end'
---
Source: task ^dbr1dqy (T1 audit, done). The audit comment "kinds of waits checked and left" names this helper change as not made: `waitForPrompts` with an end on the pump end (MailQueueFixtures / PumpProbeBackend). Reason given: the failure event (pump end, mail terminal) signals a different ChangeSignal, not `backend.changes`.

Rule T1: each wait in a test must also end on the failure event (run settle, session close, stream end), or the test must fail before it waits. A fixture closes also when the test body throws.
Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is permitted. Do not change production code only for a test hook. When a case needs such a change, bring it to the coordinating session (swissarmyhammer-96) before you change it. Do not use `.timeLimit`, sleep, poll or retry. Run the full suite one time.
Work rules: do the work in one agent. Do not run parallel agents on the tree. Edit files only with the edit tool. Do not run swift format.

Helper (checked against the code on 2026-10-17):
- `PromptCountingBackend.waitForPrompts(_:)` in Tests/FoundationModelsRouterTests/Helpers/MailQueueFixtures.swift:187. It calls `changes.wait(untilAtLeast:of:)` on the backend signal. Conformers: `SessionMessagePumpTests.PumpProbeBackend` (MailQueueFixtures.swift:192) and `BackgroundingBackend`.

Failure event to use: the end of the answer task that must send the prompt, or the pump end / settle of the session when the test has it. These events already exist. Two forms are possible, both only in test helpers:
- `RecordedWaitResult.wait(for: { try await backend.waitForPrompts(n) }, endingOnEndOf: answerTask)` (Helpers/RecordedWaitResult.swift:105).
- `changes.wait(until:endingOn:)` (Helpers/ChangeSignalWait.swift:71), when the failure state is readable and the backend signal also changes at that event.
Choose one form, add it to the helper as one member (for example `waitForPrompts(_:endingOnEndOf:)`), and use it at each site where a failure event exists.

Waits that depend on the helper:
- [x] Add the new member to the PromptCountingBackend extension in MailQueueFixtures.swift.
- [x] Helpers/MailQueueFixtures.swift:165 (`waitForPrompts(heldAnswerPrompts)`).
- [x] MailSubscriptionTests.swift:138.
- [x] MailTranscriptTests.swift:199, 242, 365, 562.
- [x] OriginAndTerminalEventTests.swift:252, 373, 419, 467, 503.
- [x] RunMessageDeliveryTests.swift:170, 187, 194, 213, 221.
- [x] SessionMessagePumpTests.swift:305, 371, 392, 416, 447, 484, 519, 529, 552, 683.
- [x] SubmissionAnswerEventTests.swift:78, 105, 139, 193.
- [x] For each site, name the failure of the test and the event that comes also in that failure. When the backend holds all work (no event comes), leave the site and write the reason in a comment on this card.
- [x] Run the full suite one time (`swift test`). Record the counts in a comment. #t1-followup