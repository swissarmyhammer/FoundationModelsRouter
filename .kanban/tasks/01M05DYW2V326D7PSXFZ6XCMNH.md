---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m05e5adqv02s8nvmm80k75kh
  text: |-
    ### What the consumer actually needs — a signal, not a limit

    The `FoundationModelsMultitool` session agrees that the design stays open, and that "no bound" is an acceptable recorded decision.

    They add the useful property: from outside, **a stuck decode is indistinguishable from a slow one**. That is why their search took three sessions.

    Something of the form "this generation has produced no token in N seconds" would have ended the search immediately. It commits us to no kill, no cancellation, and no change to the result.

    So prefer a diagnostic before a limit. A signal is useful even if we decide to bound nothing.
  timestamp: 2026-08-16T14:03:41.879224+00:00
position_column: todo
position_ordinal: '8180'
title: Generation has no timeout, no stall detector, and no diagnostic
---
A decode that never progresses hangs the caller of `respond(to:)` with no signal of any type.

## What exists today

There is no wall-clock timeout, no deadline, no watchdog, and no token-progress or stall detector on the generation path. A sweep of `Sources/` for `timeout|deadline|watchdog|sleep(|ContinuousClock|DispatchTime` gives hits in only two subsystems, and neither one bounds a decode:

- `DetachingTool` — `waitSeconds` (default 5, `Hosting/DetachingTool.swift:59`) and `timeout` (default 120, `:65`). These bound a **tool call**.
- `SessionMailbox` / `ToolContext.waitSecondsCeiling` (86400, `Hosting/ToolContext.swift:42`) — this bounds a **run-plane wait**.

`parkedRunDrainRoundLimit` bounds only the drain that runs after the turn. It never bounds generation.

Router cannot see a stall on the `respond` path, because `liveSession.respond` gives back one string. Only `streamResponseFragments` sees increments, and nothing times them.

## Cancellation is advisory only

`cancelCurrentTurn()` records flags and calls `inFlightModelCall?.cancel()` (`Session/RoutedSessionActorTurnGating.swift:65`). This is cooperative `Task.cancel()` on the task inside the backend call. Whether it unwinds belongs to `MLXLanguageModel`'s `Executor`. `RoutedSessionActorTurnExecution.swift:508-510` says the constrained decode "runs entirely inside `MLXLanguageModel`'s `Executor`, invoked by FoundationModels, never by a loop of our own".

`Tests/FoundationModelsRouterTests/TurnCancellationTests.swift:1274` asserts the limit as intended behaviour: "a turn whose model work ignores cancellation still completes — Router stopped listening, the work did not stop."

## Why this matters

A consumer that hits a stuck decode gets an indefinite hang at 0.0% CPU with no log, no event, and no error. The `FoundationModelsMultitool` session lost 15 minutes on one run before they stopped the process. They had to instrument their own code with `os_log` spans to find where the call stopped.

This card is about the missing signal, not about the deadlock. The deadlock has its own card, but a bound or a diagnostic would have made it visible in seconds instead of hours.

## Open design questions

- Is a wall-clock timeout correct, or does it report failure for a decode that is only slow?
- Is a token-progress detector better, and can Router see tokens on the non-streaming path at all?
- Is a diagnostic enough on its own — an event or a log when a turn is in flight longer than some limit — with no change to the result?

Answer these before you implement. A limit that is too small is worse than none.

## Acceptance Criteria

- [ ] Recorded which bound the Router gives: a timeout, a stall detector, a diagnostic only, or a documented decision to give none
- [ ] A turn that makes no progress produces some signal a consumer can see
- [ ] The chosen behaviour is stated in `respond(to:)`'s documentation
- [ ] Tests cover the chosen behaviour

Reported by the `FoundationModelsMultitool` session. #bug #nested-generation #long-running