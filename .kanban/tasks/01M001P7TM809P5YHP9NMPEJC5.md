---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m002p3vc115z8qj4atc84v2v
  text: |
    Picked up. Research of the run plane in this tree:

    - `RoutedSessionActor.respond(to:maxTokens:)` calls `generate(grammar:prompt:onEvent:_:)`, which drains only `outbox.drainPendingEvents()` (the content plane). Nothing awaits `mailbox`.
    - A tool call that detaches parks in `SessionMailbox` through `DetachingTool.detach(...)` and hands the model a `PendingRunEnvelope` string (the token).
    - Order guarantee that makes a drain possible: `DetachingTool.settle(...)` awaits `funnel.settleRun(with: terminal)`, which awaits the upstream `outbox.post(event:)` BEFORE the settling task's value resolves. `SessionMailbox.park` observes that same value and only then calls `markSettled`. So when `mailbox.wait(completionToken:seconds:)` reports `.settled`, the terminal `.completed` event is already staged in the outbox and the next `generate()` folds it into the prompt preamble.
    - So `respond` can self-drain with no new plumbing between the planes: wait for the parked runs to settle, then run one more ordinary turn whose drain carries their terminals.
    - `sweep()` is teardown only, and must stay that way.
  timestamp: 2026-08-14T12:06:57.132548+00:00
- actor: claude-code
  id: 01m00675arag7yct1s5txyh16j
  text: |
    Implementation landed. The termination rule, stated plainly for the consumer session:

    **Bounded re-entry over the whole run plane.** `respond(to:)` runs its own turn, then repeats: take a snapshot of every run parked on the session's mailbox, wait for ALL of them to settle, then run one drained continuation turn whose prompt carries their results as the ordinary drain-on-turn preamble. At most `RoutedSessionActor.parkedRunDrainRoundLimit` (= 4) such continuation turns run, so the worst case is 5 model turns for one `respond`.

    It is deliberately NOT "drain only what this call's turn parked":
    - Each round drains **every** run parked at that moment, not the first, so a turn that backgrounds two tools is answered from both.
    - The snapshot is the whole run plane, not this turn's own parkings, because assertion 2 ("no parked runs left after the call returns") is a statement about the session.
    - A run parked from inside a drained turn IS drained — that is the case the round bound exists for, covered on purpose by a test rather than by accident.

    Three other exits, all documented on `respond(to:maxTokens:)`:
    - a run that has not settled within `ToolContext.waitSecondsCeiling` (a further turn could not carry its result anyway);
    - `cancelCurrentTurn()` landing on this call, observed through the new monotonic `RoutedSessionActor.cancelRequestCount` — needed because a detached tool call answers a cancellation by detaching, so the turn returns a response rather than throwing, and `endTurn()` has already cleared `cancelRequestedTurnId` by the time the drain looks;
    - the caller's own task being cancelled. A cancelled turn is never drained.

    Behaviour deliberately unchanged: `streamResponse`/`streamEvents` still return while their runs are in flight, and `sweep()` stays teardown-only.

    Discoveries worth keeping:
    - A cancellation that lands INSIDE a drain wait is not observed until that run settles (`SessionMailbox.wait` ignores task cancellation and `cancelCurrentTurn()` reports `.noTurnInFlight` between turns). Filed as `^h3efdrc`.
    - `SessionOutboxToolWiringTests`'s turn-cancellation test had to move its run-plane read to before the drain: it asserted "still parked" AFTER `respond` returned, which the new contract makes false. Reading the run plane while the work is in flight keeps the test's subject intact. Left un-drained, that test blocked for the tool's whole default timeout (509 s) — the first sign that a cancelled turn must skip the drain.
  timestamp: 2026-08-14T13:08:41.432536+00:00
- actor: claude-code
  id: 01m0068d46zhm6ktsvjc0hgryt
  text: |
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift (the drain, `parkedRunDrainRoundLimit`, `drainedRunContinuationPrompt`, `settleParkedRuns()`, the doc comment), Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift (`cancelRequestCount`), Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnGating.swift (count the request), Sources/FoundationModelsRouter/Session/RoutedSession.swift (public docs for respond/streamResponse/streamEvents), Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift (new suite, 3 tests), Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift (turn-cancellation test reads the run plane in flight), docs/Usage.md.
    - termination rule: bounded re-entry over the whole run plane — one turn of its own plus at most `parkedRunDrainRoundLimit` (= 4) drained continuation turns, each waiting for every run parked at that round; exits early on an unsettled run past `ToolContext.waitSecondsCeiling`, on `cancelCurrentTurn()`, and on caller-task cancellation.
    - tests: `swift build` clean; `swift test` 936 tests in 88 suites pass (plus 27 and 24 in the other targets), zero failures, zero new warnings. The only warning is upstream mlx's pre-existing `missing creator for mutated node`.
    - follow-up filed: `^h3efdrc` — `cancelCurrentTurn()` cannot stop a `respond()` already parked inside its drain wait.
    - next: /review
  timestamp: 2026-08-14T13:09:22.182093+00:00
- actor: claude-code
  id: 01m006pyqd91cyetpeqhhnwvrk
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (d2be019) — 0 findings, 0 confirmed, 0 refuted; 16 validators attempted, 0 failed, 0 skipped
    - next: task moved to done; no findings to record
  timestamp: 2026-08-14T13:17:18.957404+00:00
- actor: claude-code
  id: 01m006qj6byt92fhhrfv09ta3p
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 7 files. `respond(to:maxTokens:)` runs its own turn, then drains the run plane: it waits for every parked run to settle and runs a further turn carrying those results. Termination rule: bounded re-entry over the whole run plane — at most `parkedRunDrainRoundLimit` (= 4) drained continuation turns, with early exits on the run plane's wait ceiling, on `cancelCurrentTurn()` and on caller-task cancellation. `streamEvents`/`streamResponse` unchanged.
    - test: green — one bare `swift test`, 987 tests in 3 targets (936 + 27 + 24), 0 failures, 1 known pre-existing BoundedWait issue. The only warning is the pre-existing upstream Cmlx bundle warning, which no file in this repository controls.
    - commit: d2be019 feat(session)!: respond(to:) self-drains the run plane before it returns (^nmpejc5)
    - review: clean — 0 findings, 16 validators attempted, 0 failed, 0 skipped.
    - note: the consumer session (FoundationModelsMultitool) has the termination rule and has recorded it in its gated runner, so its scenarios are written against the real rule.
  timestamp: 2026-08-14T13:17:38.891970+00:00
position_column: done
position_ordinal: ffa680
title: respond(to:) must self-drain the run plane before it returns
---
Filed by the `FoundationModelsMultitool` session as the consumer requirement behind its card `^n6kgckr`.

## What we found in this tree

`respond(to:maxTokens:)` (`Session/RoutedSessionActorGeneration.swift:18`) awaits **generation only**. Its own comment says it composes the prompt with "whatever the outbox drains for this turn" — the outbox, not the run plane. Nothing in that file touches the mailbox.

`sweep()` is teardown driven by `close()`: it *cancels* parked runs and synthesizes their terminals. It is the opposite of draining them.

So today a `respond` turn that parks a run returns with the run still parked, and its result reaches the model only if a *later* turn folds it in.

## Why that is now a defect rather than a design choice

`FoundationModelsMultitool` just made `runCode` **always** background (its `^cv98vff`). A turn's tool call no longer returns data — it returns a reference to work still running. So on `respond`:

- The model writes its answer from **a token and nothing else**. That is not hypothetical; it is the failure already measured on the streaming surface before the run plane existed: `invoked=[] returned=[]`, and an answer of "I don't have access to real-time weather data".
- The caller asked for FoundationModels semantics — block, then give me the answer — and got a surface that returns before the work it started has finished.

On streaming, backgrounding is the feature. **On `respond`, backgrounding must be invisible: the same final answer, just slower.** That is what keeps `respond` a real FoundationModels surface rather than a degraded one.

## The requirement

Before `respond(to:)` returns, every run that turn parked has settled and its result has reached the model's context. Concretely, a consumer must be able to assert all four:

1. the answer is **grounded** in what the backgrounded tool actually returned, not in the token;
2. after the call returns, the session has **no parked runs left**;
3. the caller never had to call a `wait` tool to get there — if the model must call `wait` on this surface, the drain is not doing its job;
4. the same scenario through `respond` and through a drained `streamEvents` reaches the **same** final answer.

## The hazard to design against

A drain that feeds settled results back to the model invites another turn, which may park more runs. The loop must terminate. Whether that is "drain only what this call's turn parked", a re-entry bound, or something else is Router's call — but a `respond` that can spin forever is worse than one that returns early, so the termination rule belongs in the design, not in a follow-up.

Please also say plainly, in the `respond(to:)` doc comment, which surface drains what. A consumer reading it today cannot tell that the outbox and the run plane are different things that drain at different times.

## The termination rule chosen

**Bounded re-entry over the whole run plane.** `respond(to:)` runs its own turn, then repeats: snapshot every run parked on the session's mailbox, wait for all of them to settle, run one drained continuation turn carrying their results as the turn's preamble. At most `RoutedSessionActor.parkedRunDrainRoundLimit` (= 4) continuation turns, so one `respond` costs at most 5 model turns. Each round drains every parked run, not the first; the snapshot covers the whole run plane, not only this turn's own parkings. A run parked from inside a drained turn is drained too — the case the bound exists for. Three other exits: a run outlasting `ToolContext.waitSecondsCeiling`, a `cancelCurrentTurn()` landing on this call (observed through the monotonic `cancelRequestCount`), and the caller's own task being cancelled. A cancelled turn is never drained.

## Acceptance Criteria

- [x] `respond(to:)` does not return while a run parked by its own turn is still in flight
- [x] The settled result reaches the model in the same call, so the answer is written from the data rather than from a token
- [x] The termination rule is chosen, documented, and covered by a test that parks a run from inside a drained turn
- [x] `streamEvents` behaviour is unchanged — backgrounding stays the feature there; a shared drain must not quietly make streaming block too
- [x] The `respond(to:)` doc comment says what it drains, and what it does not
- [x] `swift build` clean and `swift test` green


#eventplan