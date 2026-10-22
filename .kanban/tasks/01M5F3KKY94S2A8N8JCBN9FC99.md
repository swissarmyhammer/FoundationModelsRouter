---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f65xzjvmy3gnkavsb5qc45
  text: |-
    ### decision — user (2026-10-21)
    - Working and idle come from workStarted and workEnded, not from submissionEnded. A session is working from the first submission of a chain until the whole chain of work ends, so it never reports idle in the middle of a tool loop.
  timestamp: 2026-10-21T12:15:06.738742+00:00
- actor: claude-code
  id: 01m5gdfr2sfegfhdt0vg0awh5w
  text: |-
    ### research — picked up
    - Decision applied (user, 2026-10-21): workStarted gives working, workEnded gives idle unless a question is still open; submissionStarted/submissionEnded change nothing. The "Blocked on a spec decision" section of the card is answered.
    - Measured (swiftc probe in the scratchpad): an `AsyncStream` does NOT finish when its last continuation is released. So a session released without `close()` leaves a `streamSessionEvents()` feed waiting for ever, whether or not the feed task holds the session weakly. Plan: `RoutedSessionActor.deinit` also finishes the feeds of its `outputHub` (`finishFeeds()`), and the directory feed task holds no session at all (it reads the session from the weak entry when it needs it).
    - `streamSessionEvents()` is actor-isolated, and `register` is synchronous (makeSession is sync). To miss no event between the registration and the first read, the directory makes the feed synchronously through `RoutedSessionActor.outputHub.makeFeed()` (the same downcast `writeMissingFacts` makes); another conformer gets its feed through `await streamSessionEvents()` inside the task.
    - A form answer (`respond(elicitationId:response:)`) sends no event that names the question, so the reducer cannot know from events alone that the question closed. On `workEnded` the directory reads `openElicitationIds()` and gives that list to the reducer (RoutedSession doc: "a session with no work and one or more open questions waits only for external input").
    - `workEnded` comes after the `elicitationRequested` of a run that now waits only for the user (SessionWorkEventTests), so the order needsInput -> workEnded keeps needsInput.
    - A multi-submission chain for the test: `SessionMessagePumpTests.PumpProbeBackend` with `[1: .holdThenReject(latch)]` (rejected tool call, then a continuation submission). A held turn: `[1: .hold(latch)]`. Elicitation: `SessionWorkEventTests.AskingTool` over `BackgroundingSessionFixture`.
    - Re-registration of a live session keeps its tracked state and feed; unregister cancels the feed task.
    - Spec text that still states the literal mapping: FoundationModelsRouter/session.md 5.5 and FoundationModelsMultitool/session.md section 7 (`stateChanged` row). Not edited here (outside the card's file list); flagged in the report.
  timestamp: 2026-10-21T23:42:02.841607+00:00
- actor: claude-code
  id: 01m5gf47cps6ctaxpktvwpmgbm
  text: |-
    ### implementation landed
    - `Directory/SessionStateTracking.swift`: pure reducer `apply(event:)`, `replaceOpenQuestions(with:)`, `archive()`; `lastSummaryLength = 500` (Character prefix). Exhaustive switch, no `default`.
    - `RouterSessionDirectory`: `Entry` holds `tracking` and the `stateFeed` task. `register` starts the feed task under the same lock that sends `started`; a second registration of a live session keeps tracking, feed and `updatedAt`; `unregister` and the prune in `liveSummaries()` cancel the task. `recordState(after:of:)` applies each event under the lock and sends `stateChanged` only when (state, lastSummary) changed, and sets `updatedAt`. At `workEnded` it first reads `openElicitationIds()` of the session. Internal `stateFeed(of:)` for the tests.
    - `RoutedSessionActor.deinit` now also calls `outputHub.finishFeeds()` (Session layer change, outside the directory file). Needed because an AsyncStream never finishes when its continuation is released; checked by mutation: without it the leak test hangs.
    - Mutation check: `workEnded -> idle` always makes "while the question of a run is open ... its answer gives working" fail.
    - Decision made here: every `stateChanged` carries the current `lastSummary` (also with working), and an answer while the session still works sends `stateChanged(working, reply)` as the card says ("each change of state or summary"). The Extras InMemorySessionDirectory double sends `lastSummary: nil` with working/needsInput; flag for the reviewer if the port contract means "only with idle".
    - Known gap (documented in the reducer doc): a form answer while the session still works sends no event, so `needsInput` stays until the next `workEnded`, which then reads the session's open questions.
    - Spec text still states the literal submission mapping: FoundationModelsRouter/session.md 5.5 and FoundationModelsMultitool/session.md section 7. Not edited.
    - Full `swift test`: 2058 tests in 255 suites passed (9 known issues are pre-existing `withKnownIssue` tests), build has no code warnings.
  timestamp: 2026-10-22T00:10:42.454798+00:00
- actor: claude-code
  id: 01m5gf49mpdc13tk3ddamx9qq1
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift (new), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift (doc), Tests/FoundationModelsRouterTests/SessionStateTrackingTests.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryStateTests.swift (new); `swift test --filter "SessionStateTracking|RouterSessionDirectoryState"` 22/22 pass; full `swift test` 2058 pass
    - next: /review
  timestamp: 2026-10-22T00:10:44.758502+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: doing
position_ordinal: '80'
title: 'ROUTER-9: Session state (working, needsInput, idle, archived) and the 500-character last summary'
---
## Goal
The directory maps the events of each live session to a `SessionState` and keeps the last final message, cut to 500 characters, as `lastSummary`; each change sends `stateChanged`.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-9-session-state-and-last-summary
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.5
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 7 (`stateChanged` sources) and 13.3

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift`: a pure reducer `(state, SessionEvent) -> (state, lastSummary?)`, so each mapping has a unit test with no session.
  - Spec mapping: `submissionStarted` gives `working`; `elicitationRequested` gives `needsInput`; `submissionEnded` and `answered` give `idle`, and `answered(SessionAnswer)` sets `lastSummary` to `SessionAnswer.reply` cut to 500 characters; an archive gives `archived` (ROUTER-11 calls it).
  - **Code finding (settled by the user on 2026-10-21):** `SessionEvent.submissionEnded` comes once for each submission of a chain (a tool loop or an overflow retry sends more than one, `Session/SessionEvent.swift`), so a literal `submissionEnded -> idle` flickers to idle in the middle of a turn. The session already sends `workStarted`/`workEnded` (`Session/SessionEvent.swift`, carried only by `RoutedSession.streamSessionEvents()`), which come in turns and mean "work" and "no work". Decided: `workStarted` gives `working`, `workEnded` gives `idle` unless an elicitation is still open, `elicitationRequested` gives `needsInput`, `elicitationEnded`/`elicitationCompleted` give `working` again; `answered` only sets `lastSummary`.
  - A rule never asks (D64): no rule denial event (ROUTER-7, not built yet) maps to `needsInput`. Only `elicitationRequested` can give `needsInput`.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`: on `register`, start one task that reads `session.streamSessionEvents()` and applies the reducer; the task ends when the feed ends (close). The summary's `state` and `lastSummary` come from it. Each change of state or summary sends `stateChanged(id:state:lastSummary:)` once (no event when nothing changed), after the session's `started`.

## Subtasks
- [x] Failing test first: reducer table test for each mapped event, and a test that cuts a 600-character reply to 500 characters.
- [x] A test over every `SessionEvent` case other than `elicitationRequested` that none gives `needsInput`.
- [x] Wire the reducer into the directory with one feed task for each live session; it stops at close.
- [x] Scripted-model integration test: working during a turn, idle with the last summary after it, `needsInput` during an elicitation (use the existing elicitation fixtures of `Tests/FoundationModelsRouterTests`).
- [x] `stateChanged` comes after `started` and only on a change. Leak test: release a registered session without `close()`; the session deallocates and its feed task ends (`RoutedSessionActor`'s `deinit` does not finish `streamSessionEvents()` today, so the feed task must hold the session weakly or the directory must end it when the weak entry clears).

## Acceptance Criteria
- [x] During a turn, `summary(of:)` gives `working`; after it, `idle` with `lastSummary` equal to the reply (cut to 500 characters).
- [x] During an open elicitation, the state is `needsInput`.
- [x] A turn with several submissions (a tool call loop) never reports `idle` before its answer.
- [x] Each state change sends one `stateChanged`; `started` is first.
- [x] A session released without `close()` deallocates, and its feed task ends.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionStateTrackingTests.swift`
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryStateTests.swift`
- [x] `swift test --filter "SessionStateTracking|RouterSessionDirectoryState"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api