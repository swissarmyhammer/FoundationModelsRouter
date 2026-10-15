---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4ygq1pag4grg39eqgr4gcjm
  text: |-
    Research (implement step).
    - Extras run plane: a question leaves without a client answer only in the private `cancelQuestions` (run cancel `cancel(completionToken:)` and `sweep()`), always with `.cancel(reason: RunPlane.runCancelledReason)`. A duplicate id gets `.cancel(reason: duplicateElicitationIdReason)` before the post, so it has no elicitationRequested and gets no end event. The run plane has no hook for an ended question. Router can see the end with no Extras change: `RunPlane.openElicitations()` (public) tells that the question left, and the session's own record (`askedQuestions`) tells that no client answer resumed it. The documented contract of the run plane then gives the response: `.cancel(reason: RunPlane.runCancelledReason)`.
    - Router does not call `cancel(completionToken:)` (a tool calls it through ToolContext). The cancelled run posts its terminal, and the journal records it in `record(event:origin:)` with the origin of the run mail. That is the place for the run-cancel end: before the live `runSettled`, with the same origin, so before the answer that delivers that mail.
    - `cancelAll()`: `performCancelAll()` starts the sweep in a task and does not wait, so `signalDone` can come before the sweep. Thus the session ends the open questions itself in `performCancelAll()` (before `startSweep()`), with the origin of the signal, and refuses a later client answer to them. close() does the same first with origin `.system`, before `finishSessionEventSubscriptions()`.
    - Race: a client answer in flight (between `noteWorkStart` and `noteAnswer`). The session counts answers in flight per question; an end check skips such a question and keeps the origin; `noteAnswer` then sends the end only when the run plane had no question (`.noPendingElicitation`).
  timestamp: 2026-10-15T00:52:08.010496+00:00
- actor: claude-code
  id: 01m4yh49y8ys3n6qk26qcvkm9r
  text: 'RED seen (stub record API, no session wiring): `swift test --filter "ElicitationEndedEventTests|AskedQuestionsEndTests"` -> "Test run with 7 tests in 2 suites failed ... with 9 issues". Run cancel, cancelAll and close tests fail at `ends.count == 1` (no end event); the three record tests fail on the deferred end and the refused late answer; the answered-question test passes (it asserts no end). All fail by assertion, none hangs.'
  timestamp: 2026-10-15T00:59:22.440875+00:00
- actor: claude-code
  id: 01m4yhf6z3ffjtn54fgtt3v9cm
  text: |-
    API recorded (implement step).
    - New public case, next to workStarted/workEnded: `SessionEvent.elicitationEnded(ElicitationEnd)`.
    - New public payload: `public struct ElicitationEnd: Sendable, Equatable { public let elicitationId: ULID; public let response: ElicitationResponse; public init(elicitationId:response:) }`. `elicitationId` is the id of the `elicitationRequested`. `response` is the cancel or decline that the run got, with its `reason` (never an accept). Today each end carries `.cancel(reason: RunPlane.runCancelledReason)`, because the run plane ends a question with no client answer only for a stopped run.
    - Origins: run cancel -> the origin of the run terminal (`.mail([id])` of the run mail), sent before that `runSettled`, thus before the `answered` of that mail. `cancelAll()` -> `.signal(id)`, sent before `signalDone`. `close()` -> `.system`, sent before the feeds finish.
    - Behavior change: `respond(elicitationId:response:)` and `complete(elicitationId:)` for a question that ended this way give `.noPendingElicitation` and do not reach the run plane (cancelAll ends the questions before its sweep cancels them on the run plane).
    - Internal: `AskedQuestions` keeps the run token, an `.ended` state, the count of answers on their way and a deferred end origin. New file `RoutedSessionActorQuestionEnds.swift` (end check in `record(event:origin:)` for `.completed`, `endOpenQuestions(at:)` in `performCancelAll()` and `close()`, `beginAnswer(to:)` in `deliverAnswer`).
    - Consumers in other packages (Agents demo, ACPAgent translator, Multitool ScenarioRunner) must add the case; this repo did not change them.
  timestamp: 2026-10-15T01:05:19.843396+00:00
- actor: claude-code
  id: 01m4yhffczq49qb71r3sceegt2
  text: |-
    step: implement
    outcome: changed
    evidence: new files Sources/FoundationModelsRouter/Session/ElicitationEnd.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorQuestionEnds.swift, Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift; changed SessionEvent.swift (case elicitationEnded), RoutedSessionActorWorkEvents.swift (AskedQuestions), RoutedSessionActorRunJournal.swift, RoutedSessionActorDrain.swift, RoutedSessionActorForking.swift (close), RoutedSessionActorQueueing.swift, RoutedSession.swift (docs), SessionObserver.swift, SessionAnswer.swift, SessionOutputHub.swift, RoutedSession.md, Examples/MultiModelGeneration/main.swift, IntegrationTests RealToolAnswerComparisonTests.swift, Tests ScriptedToolAnswerComparisonTests.swift, SessionWorkEventTests.swift (helpers internal), Helpers/SessionOutputPositions.swift. New public API: `SessionEvent.elicitationEnded(ElicitationEnd)`, `ElicitationEnd { elicitationId: ULID; response: ElicitationResponse }`. RED: "Test run with 7 tests in 2 suites failed ... with 9 issues" (assertions, no hang). GREEN: "Test run with 7 tests in 2 suites passed"; touched suites "Test run with 20 tests in 4 suites passed"; `swift build --build-tests` "Build complete!" with no warning; full `swift test --skip-build` "Test run with 1717 tests in 208 suites passed ... with 1 known issue" (the known issue is the existing RealModelHarness embedding tripwire), plus "25 tests in 13 suites passed" and "19 tests in 3 suites passed"; `cd IntegrationTests && swift build --build-tests` "Build complete!". Not committed; card left in doing.
    task: ^fqb5rjr
  timestamp: 2026-10-15T01:05:28.479438+00:00
- actor: claude-code
  id: 01m4yj1wh546zrra1rj84xaaz9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (51062c5c), engine counts findings 1, confirmed 1, refuted 1; 2 hand-check findings. Open: Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift:159, Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift:353, Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:404.
    - hand checks with no finding: at Extras 7f530ff, the run plane removes an open question only through respond, complete, cancel(completionToken:) and sweep. Cancel and sweep always give `.cancel(reason: RunPlane.runCancelledReason)`. A duplicate id never enters the list and posts no event. Extras has no decline and no timeout path, and a run that ends normally leaves its question open. Thus the assumed response is correct. The sweep after cancelAll()/close() gives no second end, because the record marks the question as ended. The docs of respond/complete for .noPendingElicitation agree with the record. The tests use gates and no clock.
    - next: implement the three open findings, then review again.
  timestamp: 2026-10-15T01:15:31.749902+00:00
- actor: claude-code
  id: 01m4yj2htkmdqek35kwyd2nvv7
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionEvent.elicitationEnded(ElicitationEnd), ElicitationEndedEventTests
    - test: green — full suite 1717 tests in 208 suites passed (run by implement); IntegrationTests build clean
    - commit: 51062c5c
    - review: findings — ElicitationEndedEventTests.swift:159, RoutedSessionActorWorkEvents.swift:353, RoutedSessionActorForking.swift:404
  timestamp: 2026-10-15T01:15:53.555604+00:00
- actor: claude-code
  id: 01m4yjd0t11k35tsma70jhe2qb
  text: |-
    Research for the three findings (implement step 2).
    - An answer of the client on its way never waits on the journal, a signal or close: `deliverAnswer` does `beginAnswer` (actor), `noteWorkStart` (actor + `RunPlane.openElicitations`), the run-plane call (`RunPlane.respond`/`complete` are synchronous on the run-plane actor), `mail(_:)` (synchronous), then `noteAnswer` (actor). Thus a terminal can wait for it with no deadlock.
    - Design: the record keeps, for a deferred end, HOW the end goes out (`QuestionEndDelivery`: `.runEvent(RunEventOrigin)` for the run-terminal check, `.session(Origin)` for cancelAll/close). A question with a deferred end is no longer open: a later end check or a later answer does not touch it, so its first owner sends exactly one end. `noteAnswer` sends the deferred end through the same delivery as the non-deferred end, then signals a new `ChangeSignal`. The run terminal (before `runSettled`), `performCancelAll()` (after `startSweep()`, before `signalDone`) and `close()` (before `finishSessionEventSubscriptions()`) wait until the answers to the questions they deferred returned. The wait runs in a task of its own, because a cancel of the caller of close() must not end it.
    - Test seam: `deliverAnswer` becomes internal so a test gives a run-plane call that waits at a gate. The test cue is `stateChanges.signal()` when an end check defers an end (existing test-only signal), read through `hasDeferredEnd`. For cancelAll and close the test also waits for `RunPlane.joinRunBodies()` (the body ends only after the sweep removed the question) before it opens the gate.
  timestamp: 2026-10-15T01:21:36.577777+00:00
- actor: claude-code
  id: 01m4yjnk41g9ps6jyyz56rghv3
  text: 'RED seen (test seam only: `deliverAnswer` internal, `AskedQuestions.hasDeferredEnd(of:)`, `stateChanges.signal()` after each end check; no behavior change): `swift test --skip-build --filter ElicitationEndedEventTests` -> "Test run with 11 tests in 2 suites failed after 0.035 seconds with 5 issues". Run cancel with an answer on its way: `end.position < settled` failed. cancelAll with an answer on its way: `end.origin == .signal(signal)` failed (the run-terminal check overwrote the deferred origin) and `end.position < signalDone` failed. close with an answer on its way: `ends.count == 1` failed (zero ends: the feeds ended first). All by assertion, none hangs. The resumed-run test and the finding-1 checks pass before the fix (guards).'
  timestamp: 2026-10-15T01:26:17.473561+00:00
- actor: claude-code
  id: 01m4yk41avtjnrj6w7pr45jfh6
  text: |-
    ### implement — changed
    - What changed: `AskedQuestions` keeps a `QuestionEndDelivery` (`.runEvent(RunEventOrigin)` or `.session(Origin)`) for a deferred end; a question with a deferred end is no longer open, so the first end check owns its one end (no overwrite, a later answer gets `.noPendingElicitation`). `endQuestions(ofRun:notIn:via:)` returns `QuestionEndCheck { ended, deferred }`. `noteAnswer` sends a deferred end through `sendQuestionEnds(_:via:)` (run-terminal ends go through `deliverLive(_:origin:)` with the drops check and the answer sink; cancelAll/close ends through `emitQuestionEnds`) and then signals the new `questionAnswerReturns` ChangeSignal. The journal (before `runSettled`), `performCancelAll()` (after `startSweep()`, before `signalDone`) and `close()` (after `performCancelAll()`, before `finishSessionEventSubscriptions()`) wait in `awaitAnswersOnTheirWay(to:)`, which runs in a task of its own so a cancel of the caller of close does not end it. No deadlock: an answer on its way waits on no terminal (`RunPlane.respond`/`complete` are synchronous). Test seam: `deliverAnswer` is internal; `stateChanges` signals a deferred end (`hasDeferredEnd(of:)`).
    - Tests: finding 1 checks (`respond`/`complete` give `.noPendingElicitation`) in the run-cancel, cancelAll and close tests; new gated tests for run cancel, cancelAll and close with an answer held before the run plane, and one with the answer held after the run plane that resumed the run (no end); new record test `theFirstEndCheckOwnsADeferredEnd`.
    - evidence: RED "Test run with 11 tests in 2 suites failed after 0.035 seconds with 5 issues" (assertions, no hang). `swift build --build-tests` exit 0, only the mlx "missing creator" line. Touched suites `ElicitationEndedEventTests|AskedQuestionsEndTests|SessionWorkEventTests`: "Test run with 19 tests in 3 suites passed after 0.293 seconds." Full `swift test --skip-build`: "Test run with 1722 tests in 208 suites passed after 9.898 seconds with 1 known issue." (the existing RealModelHarness tripwire), "Test run with 25 tests in 13 suites passed", "Test run with 19 tests in 3 suites passed". `cd IntegrationTests && swift build --build-tests`: "Build complete! (35.21 sec)". Not committed.
    - Files: Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift, RoutedSessionActorQuestionEnds.swift, RoutedSessionActorDrain.swift, RoutedSessionActorForking.swift, RoutedSessionActorRunJournal.swift, RoutedSessionActorQueueing.swift, RoutedSessionActor.swift; Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift.
    - next: review.
  timestamp: 2026-10-15T01:34:10.779178+00:00
position_column: doing
position_ordinal: '80'
title: Session event elicitationEnded for a question that ends without a client answer
---
Do not start this task until the Extras tasks 16 and 17 are done. This task fixes the ACPAgent gap ^crjmk34. It goes with workStarted and workEnded in one consumer step (Agents demo, ACPAgent translator and tests, Multitool ScenarioRunner).

Add a public SessionEvent case `elicitationEnded`. It carries:
- the elicitation id, which is the same ULID as in `elicitationRequested`,
- how the question ended: cancelled or declined, with the reason (Extras task 16).

The session sends it when a question leaves the run plane without a client answer, in order with the other outputs. elicitationEnded never comes for a question that the client answered.

Origin and order for each way that a question can end:
- Run cancel (`cancel(completionToken:)`, Extras task 17, reason "run cancelled"): origin `.mail([id])` of the run's mail, like the other run output events. It comes before the terminal event of that mail.
- `cancelAll()`: origin `.signal(id)` of the cancel-all signal, because the outputs of the silenced mail are dropped. It comes before the terminal event of the cancel-all signal.
- `close()`: origin `.system`. It comes before the output stream ends.

Depends on Extras tasks 16 (a reason in decline and cancel) and 17 (resolve the open questions of a cancelled run with cancel and the reason "run cancelled"). The reviewer asks Extras to add those cards.

Tests: one fixed-order test for each way to end; no event for an answered question; the event id matches the id of `elicitationRequested`. #elicitation-phase-1

## Review Findings (2026-10-14 20:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 18 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/ElicitationEndedEventTests.swift:159` `completeness/invariant-propagation` — The change states that after cancelAll() or close() ends a question, respond(elicitationId:response:) and complete(elicitationId:) return .noPendingElicitation. No test in this diff checks that. closeGivesTheEndBeforeTheFeedEnds only checks the end event, and the cancelAll test (line 143) checks only the end event and its position. A regression that leaves the question open after close() or cancelAll() would pass these tests. After `close()` in closeGivesTheEndBeforeTheFeedEnds, assert that `respond(elicitationId:response:)` and `complete(elicitationId:)` for the question id both return `.noPendingElicitation`. Add the same check for the cancelAll test after `signalDone`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift:353` `hand-check/order-and-origin` — A deferred end (an end check found the question gone while a client answer was on its way, `deferredEnd`) goes out only when that answer returns from the run plane. Nothing holds it before the terminal event of its work. Run cancel: `endQuestionsThatLeftTheRunPlane` sends the `runSettled` of the run at once, and the deferred end comes after it, and possibly after the answer of the run mail. cancelAll(): the `signalDone` of the signal does not wait for the answer on its way, so the deferred end with `.signal(id)` can come after `signalDone`. The card requires the end before the terminal event of that mail or signal in each case. Also, this path sends the end through `emitSessionScopedEvent` and does not apply `outputHub.drops(origin.poster)` or the sink of the running answer, as `deliverLive(_:origin:)` does for the other end path. Make the deferred end obey the order of the card (for example, the terminal event of the work waits for the answers on their way to the questions it ends), and send it through the same delivery as the non-deferred end.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorForking.swift:404` `hand-check/exactly-one-end` — close() calls `endOpenQuestions(at: .system)`. A question with a client answer on its way only gets `deferredEnd = .system` (`RoutedSessionActorWorkEvents.swift:220`). The sweep of close can then remove the question on the run plane before that answer arrives, so the answer returns `.noPendingElicitation` and `noteAnswer` sends the end. By then `finishSessionEventSubscriptions()` ended the feeds, so the end is lost: the question ended with no client answer and the client gets zero `elicitationEnded`. Make close() send the end of each such question before the feeds end (for example, wait for the answers on their way before `finishSessionEventSubscriptions()`), and add a test for this case.