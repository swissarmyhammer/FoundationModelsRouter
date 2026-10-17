---
assignees:
- claude-code
position_column: todo
position_ordinal: '9580'
title: Single-session tests that close no session, or close it only on the success path
---
Source: the audit of ^vkhrmcb (partial closes). That card is about tests that make more than one session. The audit also found tests that make one session and never close it, so the session does not close when the body throws (rule T1).

Known sites:
- `SessionDrainTests.cancelAllDoesNotWaitForTheRunningModelCall` and `SessionDrainTests.stoppedSessionAnswersAgain`: the session from `fixture.model.makeSession()` has no close. The first test also holds a model call on an `AsyncSemaphore` (`release`) with no cancel, so its `defer` must release that call before the close.
- `SessionPromptCacheKeyTests.aSessionClosedWithNoRunPlaneEventsReleasesItsKey`: the session closes in the body only (no step can throw between the make and the close, but there is no `defer`).

- [ ] Search the whole `Tests/FoundationModelsRouterTests` target for each test that makes one session and has no `defer` that closes it.
- [ ] Make each session close in a `defer` right after it is made. Use the shared helpers (`SessionFixtureLifecycle.close(_:opening:)`, `SessionFixtureLifecycle.close(_:opening:releasing:permits:)`, `SessionDirectoryFixture`). Release a held call with no cancel before the close.
- [ ] Run the full suite one time.

Do not change production code only for a test hook. No `.timeLimit`, sleep, poll or retry. Do not run swift format.
#t1-followup