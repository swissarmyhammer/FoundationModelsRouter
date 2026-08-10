---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kznxd3cc7vrcakx7n71y6wcw
  text: |-
    Picked up. Research and the reproduction of the reported fault.

    **Baseline.** `swift test --filter ElicitationRouting` — 7 of 7 tests pass in 0.021 s.

    **The hang, reproduced.** Broke the delivery path exactly as the card describes: made `RoutedSession.deliver(toElicitation:orReturn:using:)` always return its `unparseableResult` fallback, so the mailbox is never reached. Ran `timeout 120 swift test --filter ElicitationRouting`. The build finished in 4.60 s and then the run printed NOTHING — no suite start, no test result, no failure. The shell timeout killed it at the full 120 s. That is the fault: a hang, not a red test.

    **The escape hatch that already exists.** `TurnCancellationTests` carries it — `spinYieldLimit` + `spin(until:)`, then a guard that records an `Issue` and gives up rather than awaiting the parked work (`followUpTurnCompletes(on:observer:prompt:)`, `awaitCancellationReachingTheTool(_:observer:parked:)`). Its own doc comment names the reason: this test target sets no `.timeLimit` trait, so awaiting parked work hangs the whole run.

    **Why cancelling cannot rescue the wait.** `SessionMailbox.awaitAnswer(to:posting:)` parks on a plain `withCheckedContinuation`, which ignores cancellation. A run no answer reached cannot be unwound at all, so the bounded wait must never await such a run on its give-up path — the same reason `followUpTurnCompletes` cancels but does not await.

    **Sweep result (acceptance criterion 3).** Swept every suite for an unbounded await on a delivered answer. It is NOT only the named suite. Confirmed: `ToolContextTests` (5 sites), `SessionMailboxTests` (4 sites), `ElevatingToolTests` (2 sites). Also confirmed: NO `.timeLimit` trait anywhere in the `FoundationModelsRouterTests` target, and SwiftPM has no manifest-level way to set one, so every unbounded await hangs the whole `swift test` run.

    Two further unbounded-wait families were found and are deliberately NOT in this card's scope, because neither awaits a delivered answer: `SessionOutboxTests` (parks on `SessionOutbox.nextEvent()`, resumed by a later post, no bounded helper in the file at all) and `HumanWaitGateTests` (parks on `AsyncSemaphore.wait()`, a gate rather than an answer; that file already carries the modelled `spin`/`followUpTurnCompletes` hatch). Filing these as separate work.

    **Approach.** One shared helper, `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift`, rather than four private copies — four copies of one wait would be duplication. It is the `TurnCancellationTests` hatch in the shape these suites need: start the run, track completion without awaiting it, wait under a bound, then record an issue naming the run and throw `AnswerNeverDelivered`. Throwing (rather than returning an optional) keeps every existing assertion at full strength and matches `ToolContextTests.waitUntilPending`, which already records and throws.
  timestamp: 2026-08-10T13:22:14.540055+00:00
- actor: claude-code
  id: 01kznxx1vpa0p842ar2rwbxrg8
  text: |-
    ### implement — changed
    - evidence: 5 files — `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift` (new), `Tests/FoundationModelsRouterTests/ElicitationRoutingTests.swift`, `Tests/FoundationModelsRouterTests/ToolContextTests.swift`, `Tests/FoundationModelsRouterTests/SessionMailboxTests.swift`, `Tests/FoundationModelsRouterTests/ElevatingToolTests.swift`. No production source changed — `git diff Sources/` is empty.

    **The bound.** `AnswerDrivenRun<Value>` starts the work that only finishes once an answer is delivered, tracks that it finished through a small actor WITHOUT awaiting it, then `deliveredAnswer()` waits under a bound (1,000 polls at 5 ms — five seconds), records an issue naming the run, and throws `AnswerNeverDelivered`. That is the `TurnCancellationTests` hatch — bounded wait, recorded issue, give up rather than await further — in the shape these suites need, shared rather than copied into four files. The give-up path never awaits the run, because `SessionMailbox` parks on a plain `withCheckedContinuation` that ignores cancellation, so a run no answer reached cannot be unwound at all; cancelling and then awaiting would hang exactly where the bound exists to prevent hanging.

    Throwing rather than returning an optional is deliberate: every existing assertion keeps its exact expected value, so no assertion was weakened.

    **Observation 1 — the hang, before the fix.** Delivery path broken (`RoutedSession.deliver(toElicitation:orReturn:using:)` always returns its fallback). `timeout 120 swift test --filter ElicitationRouting`: built in 4.60 s, then printed NOTHING — no suite start, no test line, no failure — and was killed by the hard shell timeout at the full **120 s**. This matches the card's ~794 s manual kill.

    **Observation 2 — fail fast, after the fix.** Same break, same command: the suite **failed in 7.291 s**, 7 of 7 tests red, 20 issues, each naming the cause:

    > no answer ever reached the elicitation 01KZNXNQN7R1YNYFT8XRAK9XRG: the run is still parked, so the inbound answer route is broken

    with `Caught error: AnswerNeverDelivered()` attributed to each test's own line. 120 s of silence became 7.3 s with a file, a line, and a message.

    **Observation 3 — the sweep's treatment proven, not assumed.** A second, independent break at the mailbox (`SessionMailbox.respond` stops resuming the continuation) made the three swept suites **fail in 7.390 s** with the same readable message — 63 tests, 15 issues — instead of hanging. The treatment works where it was applied, not only in the named suite.

    **Restored and green.** Both injections fully reverted (`git diff Sources/` empty). `swift test` ungated: **778 tests / 72 suites**, plus 24/9 (integration, gated suites skipped) and 24/5 (evals) — **0 failures**. A forced recompile of all six touched files produced **no compiler warnings**; the single `missing creator for mutated node … mlx-swift_Cmlx.bundle` line is a pre-existing SwiftPM build-system warning present in the baseline run before any change.

    **Sweep detail.** Treated, because each awaits a delivered answer with no bound: `ToolContextTests` (5 sites, including `elicitAnswerArrivingImmediatelyIsDelivered`, whose own doc comment says "elicit would suspend forever" — it awaited on the test task itself with no `Task` and no bound), `SessionMailboxTests` (4 sites, including the `close()` teardown sweep's rejection), `ElevatingToolTests` (2 sites whose per-call timeout is deliberately *suspended* by the pending elicitation, so the engine's own timeout is no backstop). Left alone deliberately: `ElevatingToolTests.elevationOffRunsToCompletion`, whose gate the test itself opens — no answer is delivered to it.

    Found but NOT this card's cause, filed as `^h71b8yv`: `SessionOutboxTests` (parks on `SessionOutbox.nextEvent()`, resumed by a later post; no bounded helper in that file at all, plus an uncapped `while true` drain loop) and `HumanWaitGateTests` (parks on `AsyncSemaphore.wait()` — a gate, not an answer).
    - next: /review
  timestamp: 2026-08-10T13:30:57.270214+00:00
position_column: doing
position_ordinal: '80'
title: ElicitationRoutingTests hangs instead of failing when the elicitation delivery path breaks
---
A fault in the elicitation delivery path shows up as a **hung test suite**, not a red test. That turns a fast, legible failure into a run that has to be killed by hand.

## How this was found

While implementing `^rhrk3mz`, the implementer verified that the newly extracted helper `deliver(toElicitation:orReturn:using:)` was actually load-bearing by making it always return the fallback value — i.e. never delivering an answer.

`ElicitationRoutingTests` did not fail. It **hung**. The run was stopped manually after roughly **794 seconds**. With the file restored, the same tests pass 7 of 7 in **0.020 seconds**.

## Why it hangs

Each parked elicitation run awaits an answer that never arrives, so it waits forever. `ElicitationRoutingTests` has no bounded-spin escape hatch, so there is nothing to convert "no answer ever came" into a failed expectation.

`TurnCancellationTests` **does** have such a hatch, so the same class of fault surfaces there as a normal red test. The two suites disagree about how a stuck await is reported.

## Why it matters

A hang is worse than a failure. It gives no file, no line, and no message; it burns CI wall-clock until a timeout kills the job; and under `swift test` it can stall the whole run rather than one suite. Anyone who breaks this path in future gets a mystery instead of a diagnosis.

## Acceptance criteria

- [x] `ElicitationRoutingTests` gains a bounded wait so that a never-delivered answer fails with a clear message instead of hanging. Model it on the existing escape hatch in `TurnCancellationTests` rather than inventing a second mechanism.
- [x] Prove it works the way it was found: break the delivery path deliberately (e.g. make the helper always return its fallback), confirm the suite now **fails fast with a readable message** instead of hanging, then restore and confirm green. Report both observations.
- [x] Sweep the cause, not just the cited suite: check whether any other suite awaits a delivered answer with no bound, and give those the same treatment.
- [x] `swift test` stays green with no new warnings.

## Notes

- Out of scope for `^rhrk3mz`, which was a rename plus a parse extraction; filed separately so the discovery is not lost.
- Do NOT run gated integration tests (`FM_ROUTER_INTEGRATION_TESTS=1`) — they load a 27B model.
- Never run `swift format` / `swiftformat` in this repo. #phase-1