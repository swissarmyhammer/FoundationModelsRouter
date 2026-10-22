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
- actor: claude-code
  id: 01m5gfgvrjw8vqdbepc9kc83nt
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (0ac457bf) — engine counts 0 findings / 0 confirmed / 0 refuted (7 attempted, 0 failed; .kanban/ excluded by .reviewignore). Port-contract check requested by the orchestrator: 1 finding — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:647 sends `lastSummary` with every `stateChanged` (incl. working), while FoundationModelsExtras `SessionDirectoryEvent.swift:17-18` documents `lastSummary` "when the state is idle" and the reference `InMemorySessionDirectoryState` sends nil with working/needsInput (:324, :348, :397).
    - next: /implement ^bn9fc99 to bring `stateChanged` in line with the port contract, then /review again
  timestamp: 2026-10-22T00:17:36.530763+00:00
- actor: claude-code
  id: 01m5gfsvperkr4ppkmcvpwje0w
  text: |-
    ### port-contract fix landed (contract/session-directory-port)
    - New `SessionStateTracking.idleSummary`: `lastSummary` while the state is idle, else nil. `recordState(after:of:)` now compares and sends `(state, idleSummary)`, so `stateChanged` carries the last summary only with idle, and an `answered` while working changes only the stored summary and sends no event (updatedAt also stays then, since nothing the event carries changed). `summary(of:)` still reports the stored `lastSummary` in every state.
    - Docs updated: RouterSessionDirectory type doc and `recordState` doc, SessionStateTracking type doc.
    - TDD: RED observed for the new reducer test (4 issues: working, next turn, needsInput, archived gave the reply), the updated turn-end tests (got `stateChanged(working, reply)`), and the new directory test (second turn's working carried "answer 1"). GREEN: `swift test --filter "SessionStateTrackingTests|RouterSessionDirectory"` 72 tests in 7 suites pass.
    - Build shows one SwiftPM/llbuild line "warning: missing creator for mutated node: .../mlx-swift_Cmlx.bundle/Contents/MacOS" in both runs; it is a build-graph note about the mlx bundle, not from source.
  timestamp: 2026-10-22T00:22:31.374631+00:00
- actor: claude-code
  id: 01m5gfsy6q08cb10sr8fbybse2
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/SessionStateTrackingTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryStateTests.swift; `swift build --build-tests` ok; `swift test --skip-build --filter "SessionStateTrackingTests|RouterSessionDirectory"` 72/72 pass; finding flipped to [x]
    - next: /test, then /review
  timestamp: 2026-10-22T00:22:33.943638+00:00
- actor: claude-code
  id: 01m5gfzb9d3pkh3n2zskfjs9dm
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (e3b84de1) — engine counts 0 findings / 0 confirmed / 0 refuted (7 attempted, 0 failed; 4 files reviewed, .kanban/ excluded by .reviewignore). Prior Review Findings (2026-10-21 19:12): 1/1 checked. Port-contract check: FoundationModelsExtras Sessions/SessionDirectoryEvent.swift:17-18 ("`lastSummary` is the last final message of the session, when the state is idle") is met — `SessionStateTracking.idleSummary` gives `lastSummary` only when `state == .idle`, otherwise nil; `RouterSessionDirectory.recordState(after:of:)` compares and sends `(state, idleSummary)`; `summary(of:)` keeps the stored `lastSummary`; the type doc and the tests (RouterSessionDirectoryStateTests, SessionStateTrackingTests) pin the idle-only payload.
    - next: none — task moved to done
  timestamp: 2026-10-22T00:25:31.181806+00:00
- actor: claude-code
  id: 01m5gfzxtpkkm8yfyta2ddr81r
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — SessionStateTracking.swift (new), RouterSessionDirectory.swift, RoutedSessionActor.swift, tests
    - test: green — swift test, 2058/35/19
    - commit: 0ac457bf
    - review: findings — RouterSessionDirectory.swift:647 (lastSummary only for idle, Extras SessionDirectoryEvent.swift:17-18)
    - implement: changed — idleSummary; test: green 2060/35/19; commit: e3b84de1
    - review: clean — 0 findings
  timestamp: 2026-10-22T00:25:50.166665+00:00
depends_on:
- 01M5F3G4HNS9E19VBRV600KVMJ
- 01M5F3GXDWVK2X4CKF7KTDQB5Z
position_column: done
position_ordinal: ffffffffa880
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

## Review Findings (2026-10-21 19:12)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> The engine fleet returned 0 findings (7 attempted, 0 failed). The item below is the port-contract check the orchestrator asked for (the implementer's open question), checked against the FoundationModelsExtras `SessionDirectory` port docs in `.build/checkouts/FoundationModelsExtras`.

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:647` `contract/session-directory-port` — `recordState(after:of:)` sends `.stateChanged(id:state:lastSummary:)` with the tracked `lastSummary` for every state (working, needsInput, archived), and an `answered` while the session still works sends `stateChanged(working, reply)`. The port contract documents `lastSummary` only for idle: `SessionDirectoryEvent.stateChanged` says "`lastSummary` is the last final message of the session, when the state is idle." (`FoundationModelsExtras/Sessions/SessionDirectoryEvent.swift:17-18`), and the reference `InMemorySessionDirectoryState.changeState(of:to:lastSummary:at:)` documents the parameter as "The new last summary, for the idle state." and sends `lastSummary: nil` with working and needsInput (`InMemorySessionDirectoryState.swift:324`, `:348`, `:397`). Send `lastSummary` in `stateChanged` only when the state is idle (nil otherwise), keep `summary(of:)` reporting the stored `lastSummary`, decide whether an `answered` with no state change still sends an event under that contract (the `(state, lastSummary)` change test at `RouterSessionDirectory.swift:639`/`:644` must follow the event payload, not the stored summary), and update the type doc at `RouterSessionDirectory.swift:31` ("for each change of its state or its last summary") and the tests that pin the divergent payload (`Tests/FoundationModelsRouterTests/RouterSessionDirectoryStateTests.swift:166`, `:198`).