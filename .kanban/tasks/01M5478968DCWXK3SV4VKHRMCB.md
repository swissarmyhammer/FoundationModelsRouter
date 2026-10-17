---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m55331jt5pgkr929pw205mt4
  text: |-
    ### Implementation notes (implement)
    - Audit method: scripts listed each `.fork(`, `makeSession(`, `restoreSession(` and `restoreSessionTree(` site in `Tests/FoundationModelsRouterTests`, with the `defer` blocks of its function. Each site with no close in a `defer`, and each restored tree with forks, was read by hand.
    - A close of a session does not close its forks (`RoutedSessionActor.close()` has no cascade). So a restored tree with forks needs a close of each restored session.
    - New shared helper (test code only): `SessionFixtureLifecycle.close(_ tree: RestoredSessionTree)` in Helpers/SessionFixtureLifecycle.swift. It closes the root and each restored session under it, parents first. It replaces the local `close(_:)` and `sessions(of:under:)` copies of `RelayedQuestionContextTests`.
    - Sites corrected:
      - `SummarizerSubmissionTests`: the flash session of `closeWhileTheSummarizerWaitsTakesItOutOfTheQueue` had no close. `WaitingSummarizer.end()` now opens the flash latch and closes both sessions with `SessionFixtureLifecycle.close(_:opening:releasing:permits:)`. Both tests call it from one `defer`.
      - `GenerationStallDiagnosticTests`: the 8 tests that use `makeStallingSession()` had no close. A new `close(_:releasing:)` gives one permit to `StallingBackend.release` (an `AsyncSemaphore` with no cancel) and then closes, through the shared `close(_:opening:releasing:permits:)`.
      - `NestedGenerationReentryTests.cancelOnASessionWhoseSubmissionWaitsRemovesItAtOnce`: `holder` and `next` had no close. One `defer` now opens the latch and closes the three sessions.
      - `SessionPromptCacheKeyTests.closingAForkDoesNotReleaseItsParentsKey`: the parent had no close. Its `defer` closes it after the read of the released keys.
      - `SessionRunPlaneTests.closedSessionRestoresWithNoCallerSetup`: the restored tree had no close. The recorded session still closes before the restore.
      - `MailTranscriptTests.aRestoreReportsLostMailOneTime`: the two restored roots had no close. The live session stays open until the end, as before.
      - `RelayedQuestionContextTests` and `SubagentQuestionRelayTests.aRelayDoesNotStartForAHeadlessTarget`: the forks closed in the body only. Each now closes in a `defer` right after the make. The headless test keeps its body close before `relay?.finish()`.
      - Old `(session, dir)` pattern: `SessionRunPlaneTests`, `SubmissionBoundaryToolTests`, `PendingEventInjectionTests`, `BackgroundRunTranscriptTests` now return `SessionFixtureLifecycle.Started` and each test ends it with `defer { await fixture.end(opening:) }`. The router now stays alive until the end. `BackgroundRunTranscriptTests.aSweptRunFinishingAfterwardsJournalsNoSecondTerminal` had a real gap: the first answer could throw before the close `defer`.
    - Checked and correct already: `ExamplesTests`, `ForkConcurrencyTests` (fork arrays closed in a `defer`), `ForkTracingTests`, `SettledTranscriptTests` (children from tools in a box closed in a `defer`), `SessionSidecarTests.concurrentForksEachWriteExactlyOneSidecar` (the task group gives a `Result` for each task, so no made fork is lost), `TranscriptTreeTests.buildBranchingTree` (closes each made session on a throw), every other `restoreSessionTree` site (each fork that the test made closes in the `defer`).
    - New work found: single-session tests with no close are not in the scope of this card. Recorded as ^hr64ksq.
  timestamp: 2026-10-17T14:08:42.074883+00:00
- actor: claude-code
  id: 01m553367q7b6gftdykkrpr55e
  text: |-
    ### implement — changed
    - evidence: 12 test files changed, no production code: Helpers/SessionFixtureLifecycle.swift, SummarizerSubmissionTests, GenerationStallDiagnosticTests, NestedGenerationReentryTests, SessionPromptCacheKeyTests, SubagentQuestionRelayTests, RelayedQuestionContextTests, SessionRunPlaneTests, SubmissionBoundaryToolTests, BackgroundRunTranscriptTests, PendingEventInjectionTests, MailTranscriptTests. `swift build --build-tests`: no error, no warning. Targeted run `swift test --skip-build --filter 'FoundationModelsRouterTests\.(SummarizerSubmissionTests|GenerationStallDiagnosticTests|NestedGenerationReentryTests|SessionPromptCacheKeyTests|SubagentQuestionRelayTests|RelayedQuestionContextTests|SessionRunPlaneTests|SubmissionBoundaryToolTests|BackgroundRunTranscriptTests|PendingEventInjectionTests|MailTranscriptTests)'`: 95 tests in 11 suites passed. Full suite `swift test` one time: "Test run with 1834 tests in 225 suites passed after 3.474 seconds with 9 known issues" (the intended `withKnownIssue` tests), then 26 tests in 14 suites passed and 19 tests in 3 suites passed. IntegrationTests compiles no changed file, so it was not built. Not committed. New card ^hr64ksq for single-session gaps.
    - next: /review
  timestamp: 2026-10-17T14:08:46.839033+00:00
depends_on:
- 01M5476D8Y29HMWH8S31B1ZMQ8
position_column: doing
position_ordinal: '80'
title: 'c4 Audit partial closes: each root and fork session that a test makes closes, also on a throw'
---
Source: decision of the coordinating session on ^5xy53sw, group 4 (c).

Some tests close the root session but not a fork, or close a session on the success path only. Rule T1: a fixture closes also when the test body throws.

- [x] Find each test that makes more than one session (a root and one or more forks, or more than one root), and check that each session closes, also when the body throws.
- [x] Correct each test that misses a close. Use the shared teardown helpers (for example `SessionFixtureLifecycle.close(_:opening:)`) in a `defer`, not a new local copy.
- [x] Run the full suite one time.

Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is fine. Do not change production code only for a test hook; bring such a case to the coordinating session (swissarmyhammer-96) before you change it. No .timeLimit, sleep, poll or retry.

Work in one agent, with no parallel agents on the working tree. Edit files only with the edit tool. Do not run swift format.
#t1-followup