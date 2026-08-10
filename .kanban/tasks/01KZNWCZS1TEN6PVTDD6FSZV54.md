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
- actor: claude-code
  id: 01kznym7v8g1ycrsw0ejcjnqyw
  text: |
    ### review — findings
    - scope: review sha HEAD~1..HEAD (9680c9b)
    - evidence: 2 findings (2 confirmed, 0 refuted, 18 attempted) — Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift:54, Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift:65
    - note: the helper is new test infrastructure, so the "do not refactor pre-existing tests" exception does not apply to it. The 18 converted call sites in the pre-existing suites got no findings.
    - waivers: none. The engine raised no acronym-casing finding on this delta.
    - next: name the two constants in AnswerDrivenRun.swift, then re-review.
  timestamp: 2026-08-10T13:43:37.064538+00:00
- actor: claude-code
  id: 01kznyp6gpyqgc2xvmggq9vc7w
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 5 files. New shared `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift`; 18 call sites converted across ElicitationRoutingTests (7), ToolContextTests (5), SessionMailboxTests (4), ElevatingToolTests (2). `git diff -- Sources` empty. Hang before: `timeout 120 swift test --filter ElicitationRouting` produced NO test output and was killed at the full 120s. Fail fast after: same break, 7.291s, 7/7 red, each issue naming the stalled elicitation. Sweep proven independently by a second injection at `SessionMailbox.respond` → the other three suites failed in 7.390s instead of hanging.
    - test: green — swift test 778/72 + 24/9 + 24/5, 0 failures, no new warnings. Verified independently: `git diff -- Sources` empty before AND after the run (no injected fault survived); all four suites share the one helper rather than copying it; the give-up path never reaches `task.value` (only the success path does), which matters because SessionMailbox parks on a `withCheckedContinuation` that ignores cancellation; the bound is a real finite ceiling (1,000 × 5 ms = 5 s).
    - commit: 9680c9b — 11 files, +340/-39, local only. `AnswerDrivenRun.swift` confirmed in the commit via `create mode 100644`.
    - review: findings — Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift:54 and :65, magic numbers wanting named constants (the poll-loop iteration count and sleep interval). Engine: 18 pairs attempted, 0 failed. The 18 converted call sites drew no findings; nothing was raised against the give-up path, its doc comment, the poll-loop shape, or the API. These findings are in scope because the file is new infrastructure — the pre-existing-test exception does not shield it.
    - next: iteration 2 — name the two constants.
  timestamp: 2026-08-10T13:44:41.238962+00:00
- actor: claude-code
  id: 01kznz09v0emf78yjcq3mgv0jh
  text: |-
    Iteration 2 — the two findings on `AnswerDrivenRun.swift`.

    **The rule, read before editing.** `dump validators` returned 55 rules over 9 validators. The one that fired is `magic-numbers-swift`, which states `Supersedes: magic-numbers` — so this is a tool rule, `swiftlint`'s `no_magic_numbers`, not the prompt rule that reports by repetition. That distinction decided the fix. The prompt rule reports repetition; the tool reports by *position*, and the tool therefore reports the one-off the prompt rule carves out. Arguing "the value is used once" would have been the wrong reading.

    The rule text also names the fix precisely: measured against a probe file, swiftlint "reported nothing for a variable declaration, a stored property, a `static let`, an enumeration raw value, or a default parameter — each of those declarations names its value."

    **Reproduced the finding first, so the fix is checked and not guessed.** Rebuilt the rule's own config (`only_rules: [no_magic_numbers]`, `allowed_numbers: [0, 1, -1, 100]`) and ran swiftlint 0.65.0 against the file. It printed exactly the two reported findings, at `:54:49` and `:65:55`, with the finding's own wording: `Magic numbers should be replaced by named constants`.

    **Why the file had already-named constants and was still flagged.** The values were `private static var deliveryPollLimit: Int { 1_000 }` — *computed* properties, not declarations that name a value. swiftlint sees a bare literal in a getter body. Checked why the author wrote them that way rather than assuming: `swiftc` on a two-line probe gives `error: static stored properties not supported in generic types`, and `AnswerDrivenRun` is generic over `Value`. So `static let` inside the struct cannot compile — the constants had to leave the generic type. That is the real cause, and it is why the first pass did not clear the rule.

    **The fix.** A file-private `AnswerDeliveryBound` enum before `AnswerDrivenRun`, three documented `static let`s:

    - `ceilingNanoseconds: UInt64 = 5_000_000_000` — the whole time the wait gives an answer to arrive.
    - `pollIntervalNanoseconds: UInt64 = 5_000_000` — how long it sleeps between two questions.
    - `pollLimit = Int(ceilingNanoseconds / pollIntervalNanoseconds)` — **derived**, so the five-second ceiling is stated once as a span rather than inferred by multiplying 1,000 by 5 ms.

    The names now carry the reason: the composition into a finite ceiling is in the code, not only in a comment. It also satisfies "one place each value is defined and used" — `1_000` no longer exists in the file at all, so the count cannot drift from the interval. The naming matches the house style already in `RoutedSessionToolContextBindingTests.swift`, which carries the same `pollIterations` / `pollIntervalNanoseconds` pair with the identical 5 ms interval.

    **File-wide sweep (not only the two cited lines).** After the change the only numeric literals left in the file are the two `static let` declarations — which the rule carves out, "a literal a declaration already names" — and the `0` in `for _ in 0..<AnswerDeliveryBound.pollLimit`, which is on the rule's own `allowed_numbers` list. swiftlint under the rule's config now reports **0 violations** in the file, which is the sweep proven rather than asserted.

    **Not touched, deliberately.** `RoutedSessionToolContextBindingTests.swift` holds a second copy of the same 5 ms poll interval. It is a pre-existing file outside these two findings, so unifying it is not this card's scope.

    Did NOT re-run the fault-injection experiments — they were proven in iteration 1 and recorded above, and re-running them produces no output and hangs.
  timestamp: 2026-08-10T13:50:12.320888+00:00
- actor: claude-code
  id: 01kznz0qtc6wjrkqdcv34z7bx4
  text: |-
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift`. Both findings (`:54`, `:65`) fixed by moving the two poll-loop values out of the generic struct into a documented file-private `AnswerDeliveryBound` enum as `static let` declarations: `ceilingNanoseconds` (5 s), `pollIntervalNanoseconds` (5 ms), and `pollLimit` derived as `Int(ceilingNanoseconds / pollIntervalNanoseconds)`. The computed `static var` form could not be a `static let` in place, because Swift supports no stored static property in a generic type (`swiftc` probe: `error: static stored properties not supported in generic types`).
    - rule: `magic-numbers-swift` (`Supersedes: magic-numbers`) — swiftlint `no_magic_numbers`. Reproduced under the rule's own config before the edit (2 violations, the two reported lines); 0 violations after.
    - sweep: the whole file, not the two lines. The only literals left are the two `static let` values the rule carves out, plus the `0` in `0..<`, which is on the rule's `allowed_numbers` list. `1_000` no longer exists in the file.
    - tests: `swift test` — 778 tests / 72 suites, 24 / 9, 24 / 5, **0 failures**. The one warning is the pre-existing SwiftPM `missing creator for mutated node … mlx-swift_Cmlx.bundle` line, present in the iteration-1 baseline; no compiler warning from the changed file.
    - scope: `git diff -- Sources` is **empty** — tests only.
    - next: /review
  timestamp: 2026-08-10T13:50:26.636170+00:00
- actor: claude-code
  id: 01kznz8pa9nbws7pnwha111gv7
  text: |-
    ### test — green
    - evidence: `swift test` — 778 tests / 72 suites, 24 / 9, 24 / 5 — 0 failures. Only warning is the pre-existing baseline `missing creator for mutated node … mlx-swift_Cmlx.bundle` line; no new warnings.
    - `git diff -- Sources` is empty — this delta touched only `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift` plus kanban records.
    - Arithmetic check: `ceilingNanoseconds = 5_000_000_000`, `pollIntervalNanoseconds = 5_000_000`, `pollLimit = Int(5_000_000_000 / 5_000_000) = 1000`. The 5-second ceiling and 5 ms interval are unchanged; `pollLimit` is derived, not restated, so the two values cannot drift apart.
    - `1_000` no longer appears anywhere in the file. All three values are `static let` declarations in a new file-private `AnswerDeliveryBound` enum — not the prior `static var { 1_000 }` computed-property form swiftlint's `no_magic_numbers` flags.
    - swiftlint check run independently: swiftlint 0.65.0, config matching the `magic-numbers-swift` rule text exactly (`only_rules: [no_magic_numbers]`, `allowed_numbers: [0, 1, -1, 100]`, `--no-cache`). Result: 0 violations, matching the implementer's reported 2 before to 0 after.
    - Confirmed the pre-existing duplicate 5 ms interval in `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift` (line 159) is untouched by this delta.
    - Did not re-run fault-injection experiments (hangs, no output, per instructions). Did not run gated integration tests. Did not run swift format/swiftformat.
    - next: /review
  timestamp: 2026-08-10T13:54:47.241208+00:00
- actor: claude-code
  id: 01kznze4ykjm30cbs6nq1gm5cx
  text: |-
    ### commit — changed
    - evidence: dce5c5c test(router): move poll-loop constants into a named bound enum (^6fszv54); 3 files changed (Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift + 2 .kanban task files)
    - next: local commit only, not pushed
  timestamp: 2026-08-10T13:57:46.067244+00:00
- actor: claude-code
  id: 01kznzm4066fw5dctx6hzf2a4h
  text: |-
    ### review — clean
    - scope: review sha dce5c5c (HEAD~1..HEAD), iteration 2
    - evidence: zero new findings; 9 validators attempted, 0 failed, 0 skipped. 2 prior items checked and verified closed at Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift — the poll-loop values are now `static let` declarations that name them (`ceilingNanoseconds`, `pollIntervalNanoseconds`) in a file-private `AnswerDeliveryBound` enum, `pollLimit` is derived, and the literal `1_000` is gone from the file.
    - new code judged: `AnswerDeliveryBound` drew no finding from any validator. No acronym-casing finding appeared, so no waiver was necessary.
    - next: task moved to done.
  timestamp: 2026-08-10T14:01:01.702179+00:00
- actor: claude-code
  id: 01kznznf6y7dcef539db4f9zdw
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift. Read the rule text first, which changed the fix: the rule is `magic-numbers-swift` (swiftlint `no_magic_numbers`), which reports by POSITION, not repetition. The constants were already named but as computed properties (`static var … { 1_000 }`), and a getter body is not a declaration naming a value. They could not become `static let` in place — `AnswerDrivenRun` is generic and Swift rejects `static stored properties not supported in generic types` — so they moved to a documented file-private `AnswerDeliveryBound` enum. `pollLimit` is now DERIVED as `Int(ceilingNanoseconds / pollIntervalNanoseconds)`, so the 5 s ceiling is stated once as a span and the count cannot drift from the interval. `1_000` no longer exists in the file.
    - test: green — swift test 778/72 + 24/9 + 24/5, 0 failures, no new warnings. `git diff -- Sources` empty. Arithmetic checked rather than assumed: `Int(5_000_000_000 / 5_000_000) = 1000`, so behaviour is unchanged. swiftlint 0.65.0 run independently with the rule's exact config (`only_rules: [no_magic_numbers]`, `allowed_numbers: [0, 1, -1, 100]`) → 0 violations, corroborating the reported 2 → 0.
    - commit: dce5c5c — 3 files, +118/-18, local only
    - review: clean — zero new findings; both prior items verified closed (the two cited positions are now doc-comment prose; only the rule-exempt `0` lower bound remains). Engine: 9 validators, 0 failed. The new `AnswerDeliveryBound` enum was judged as new code and drew no finding.
    - next: task moved to done. A pre-existing duplicate of the same 5 ms interval remains in RoutedSessionToolContextBindingTests.swift — deliberately left alone as outside these findings, and noted here so it is not lost.
  timestamp: 2026-08-10T14:01:45.950070+00:00
position_column: done
position_ordinal: fc80
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
- Never run `swift format` / `swiftformat` in this repo.

## Review Findings (2026-08-10 08:39)

- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift:54` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift:65` — Magic numbers should be replaced by named constants. #phase-1