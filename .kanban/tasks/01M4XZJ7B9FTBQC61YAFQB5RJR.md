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