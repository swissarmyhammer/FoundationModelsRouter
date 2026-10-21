---
assignees:
- claude-code
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: todo
position_ordinal: 8a80
title: 'ROUTER-9: Session state (working, needsInput, idle, archived) and the 500-character last summary'
---
## Goal
The directory maps the events of each live session to a `SessionState` and keeps the last final message, cut to 500 characters, as `lastSummary`; each change sends `stateChanged`.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-9-session-state-and-last-summary
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.5
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 7 (`stateChanged` sources) and 13.3

## Blocked on a spec decision (tag needs-decision)
Which events drive working and idle: the spec's literal mapping (`submissionStarted`/`submissionEnded`) or the work events (`workStarted`/`workEnded`), for the reason given below. The acceptance criteria use the work-event mapping. If the spec owner keeps the literal mapping, rewrite the criteria before work starts. Remove the tag and this section when answered.

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift`: a pure reducer `(state, SessionEvent) -> (state, lastSummary?)`, so each mapping has a unit test with no session.
  - Spec mapping: `submissionStarted` gives `working`; `elicitationRequested` gives `needsInput`; `submissionEnded` and `answered` give `idle`, and `answered(SessionAnswer)` sets `lastSummary` to `SessionAnswer.reply` cut to 500 characters; an archive gives `archived` (ROUTER-11 calls it).
  - **Code finding to settle before work starts:** `SessionEvent.submissionEnded` comes once for each submission of a chain (a tool loop or an overflow retry sends more than one, `Session/SessionEvent.swift`), so a literal `submissionEnded -> idle` flickers to idle in the middle of a turn. The session already sends `workStarted`/`workEnded` (`Session/SessionEvent.swift`, carried only by `RoutedSession.streamSessionEvents()`), which come in turns and mean "work" and "no work". Proposed: `workStarted` gives `working`, `workEnded` gives `idle` unless an elicitation is still open, `elicitationRequested` gives `needsInput`, `elicitationEnded`/`elicitationCompleted` give `working` again; `answered` only sets `lastSummary`. This is the plan, pending the decision above.
  - A rule never asks (D64): no rule denial event (ROUTER-7, not built yet) maps to `needsInput`. Only `elicitationRequested` can give `needsInput`.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: on `register`, start one task that reads `session.streamSessionEvents()` and applies the reducer; the task ends when the feed ends (close). The summary's `state` and `lastSummary` come from it. Each change of state or summary sends `stateChanged(id:state:lastSummary:)` once (no event when nothing changed), after the session's `started`.

## Subtasks
- [ ] Failing test first: reducer table test for each mapped event, and a test that cuts a 600-character reply to 500 characters.
- [ ] A test over every `SessionEvent` case other than `elicitationRequested` that none gives `needsInput`.
- [ ] Wire the reducer into the directory with one feed task for each live session; it stops at close.
- [ ] Scripted-model integration test: working during a turn, idle with the last summary after it, `needsInput` during an elicitation (use the existing elicitation fixtures of `Tests/FoundationModelsRouterTests`).
- [ ] `stateChanged` comes after `started` and only on a change. Leak test: release a registered session without `close()`; the session deallocates and its feed task ends (`RoutedSessionActor`'s `deinit` does not finish `streamSessionEvents()` today, so the feed task must hold the session weakly or the directory must end it when the weak entry clears).

## Acceptance Criteria
- [ ] During a turn, `summary(of:)` gives `working`; after it, `idle` with `lastSummary` equal to the reply (cut to 500 characters).
- [ ] During an open elicitation, the state is `needsInput`.
- [ ] A turn with several submissions (a tool call loop) never reports `idle` before its answer.
- [ ] Each state change sends one `stateChanged`; `started` is first.
- [ ] A session released without `close()` deallocates, and its feed task ends.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionStateTrackingTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryStateTests.swift`
- [ ] `swift test --filter "SessionStateTracking|RouterSessionDirectoryState"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api #needs-decision