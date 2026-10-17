---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5568b8rmyakbexzrr9b3kh7
  text: |-
    Picked up. Research done.

    Search method: a script read each `@Test` body in `Tests/FoundationModelsRouterTests`, found each local that a session factory gives (`makeSession`, `make*Session`, `fork`, `restore*`, fixtures), and listed each one that no `defer` names. A second pass read the helper functions. I read each hit by hand.

    Sites that make one session and close it in no `defer`:
    - `SessionDrainTests.cancelAllDoesNotWaitForTheRunningModelCall` (no close; held call on the `release` semaphore).
    - `SessionDrainTests.stoppedSessionAnswersAgain` (no close).
    - `SessionDrainTests.wakeAfterCloseStartsNoPump` (close in the body only).
    - `SessionPromptCacheKeyTests.aSessionClosedWithNoRunPlaneEventsReleasesItsKey` (close in the body only).
    - `AwaitAnswerTests.aCallAfterTheCloseThrowsClosed` (close in the body only).
    - `MailSubscriptionTests.mailAndSendRefuseAfterClose` (close in the body only).

    Hits that are not defects:
    - SDK `LanguageModelSession` (ExecutorPassBoundaryTests, SessionLanguageModelPassWatchTests) and `SessionBackend` values (AnswerTokenCeilingTests, GenerationQueueTests) have no close call.
    - SessionMountCompositionTests makes tools, not sessions. RecordingDurabilityTests and TranscriptReconstructionTests write directories, not sessions. `TranscriptTree.session(_:)` reads are not live sessions.
    - Helpers that close on a throw with `removingDirectoryOnThrow(_:alsoOnThrow:_:)` or a do/catch (PlanRestorationTests, RepetitionStopRestoreTests, SessionRestorationTests, NestedRunTerminalForwardingTests, ElicitationAnswerValidationTests) are correct.
    - `NoOpToolCallModel.recordAndRestoreSession` closes the recorded session on the next line, and the restore must come after that close, so a `defer` in that closure would change the order. No change.
    - Tests that make more than one session belong to `^vkhrmcb`.
  timestamp: 2026-10-17T15:04:01.560375+00:00
- actor: claude-code
  id: 01m556dxfp2yrwrq6a575315g3
  text: |-
    Implementation landed (test code only).

    - `SessionDrainTests.cancelAllDoesNotWaitForTheRunningModelCall`: `defer { await SessionFixtureLifecycle.close([session], releasing: [release], permits: 1) }` right after `release` is made. A cancel does not end the wait on `release`, so the permit ends it before the close. The body still gives its own permit before the idle check; a permit that no wait takes does nothing.
    - `SessionDrainTests.stoppedSessionAnswersAgain`: `defer { await session.close() }` after the make.
    - `SessionDrainTests.wakeAfterCloseStartsNoPump`, `SessionPromptCacheKeyTests.aSessionClosedWithNoRunPlaneEventsReleasesItsKey`, `AwaitAnswerTests.aCallAfterTheCloseThrowsClosed`, `MailSubscriptionTests.mailAndSendRefuseAfterClose`: these tests check the close itself, so the body close stays where it is, and a `defer` close after the make covers the throw path (`close()` is idempotent).
    - `SummarizerSubmissionTests`: new `WaitingSummarizer.end(flashSession:triggered:opening:)` static holds the one teardown sequence. `end()` and the catch block of `startSummarizerBehindAFlashSubmission` call it.

    Targeted run: `swift test --filter 'FoundationModelsRouterTests\.(SessionDrainTests|SessionPromptCacheKeyTests|AwaitAnswerTests|MailSubscriptionTests|SummarizerSubmissionTests)/'` gave 50 tests in 5 suites passed.

    IntegrationTests compiles none of the changed files (its targets read only `IntegrationTests/Tests/...`), so it was not built.
  timestamp: 2026-10-17T15:07:04.054585+00:00
- actor: claude-code
  id: 01m556e0xynmjb3z8hmhsyj9bs
  text: |-
    ### implement — changed
    - evidence: 5 files — Tests/FoundationModelsRouterTests/SessionDrainTests.swift, Tests/FoundationModelsRouterTests/SessionPromptCacheKeyTests.swift, Tests/FoundationModelsRouterTests/AwaitAnswerTests.swift, Tests/FoundationModelsRouterTests/MailSubscriptionTests.swift, Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift. Full `swift test` one time: FoundationModelsRouterTests 1835 tests in 226 suites passed (9 known issues, all from existing `withKnownIssue` tests); second Swift Testing target 26 tests in 14 suites passed; Evals 19 tests in 3 suites passed; XCTest 0 tests. No compiler warning (one SwiftPM "missing creator for mutated node" note on the mlx-swift bundle, not from this change).
    - next: `/review`
  timestamp: 2026-10-17T15:07:07.582800+00:00
position_column: doing
position_ordinal: '80'
title: Single-session tests that close no session, or close it only on the success path
---
Source: the audit of ^vkhrmcb (partial closes). That card is about tests that make more than one session. The audit also found tests that make one session and never close it, so the session does not close when the body throws (rule T1).

Known sites:
- `SessionDrainTests.cancelAllDoesNotWaitForTheRunningModelCall` and `SessionDrainTests.stoppedSessionAnswersAgain`: the session from `fixture.model.makeSession()` has no close. The first test also holds a model call on an `AsyncSemaphore` (`release`) with no cancel, so its `defer` must release that call before the close.
- `SessionPromptCacheKeyTests.aSessionClosedWithNoRunPlaneEventsReleasesItsKey`: the session closes in the body only (no step can throw between the make and the close, but there is no `defer`).

Added to this card (user request): in `SummarizerSubmissionTests.swift`, the catch block of `startSummarizerBehindAFlashSubmission` repeats the cleanup sequence of `WaitingSummarizer.end()`. Both copies came from earlier `t1-followup` commits. Write the sequence one time, in one shared helper.

- [x] Search the whole `Tests/FoundationModelsRouterTests` target for each test that makes one session and has no `defer` that closes it.
- [x] Make each session close in a `defer` right after it is made. Use the shared helpers (`SessionFixtureLifecycle.close(_:opening:)`, `SessionFixtureLifecycle.close(_:opening:releasing:permits:)`, `SessionDirectoryFixture`). Release a held call with no cancel before the close.
- [x] Write the teardown sequence of `SummarizerSubmissionTests.WaitingSummarizer` one time: `end()` and the catch block of `startSummarizerBehindAFlashSubmission` both call the shared static `WaitingSummarizer.end(flashSession:triggered:opening:)`.
- [x] Run the full suite one time.

Do not change production code only for a test hook. No `.timeLimit`, sleep, poll or retry. Do not run swift format.
#t1-followup