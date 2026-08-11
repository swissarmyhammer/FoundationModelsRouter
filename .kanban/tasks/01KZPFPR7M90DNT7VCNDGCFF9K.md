---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzphrq76drccextxmctb5kf3
  text: |-
    ### Research and measurements

    **The defect, measured.** A test written first (`BoundedWaitTests`) shows the old bound in numbers. `BoundedWait.spin(until:)` with `yieldLimit = 100_000` gives up after **0.087 s** on an idle machine and after **0.121 s** under a load average of 100 on 32 cores. A signal that arrives 0.4 s later is thus lost, although the code is correct. The count of hops is not a measure of time.

    **The fix.** `spin(until:)` now reads a `ContinuousClock` deadline of `ceilingNanoseconds` (5 s). It yields for the first `yieldsBeforePolling` (1000) hops, because a state change that a test puts behind a few task suspensions lands inside those hops and costs microseconds. Then it sleeps `pollIntervalNanoseconds` (5 ms) between readings until the deadline. The sleep is important on a loaded machine: a spin that continues to yield for 5 s takes slices away from the task that must make the change.

    **The two bounds are now one.** `Helpers/AnswerDrivenRun.swift` had the same wall-clock bound with its own constants (`AnswerDeliveryBound`: 5 s ceiling, 5 ms interval, derived `pollLimit`). That enum is deleted. `finishesWithinDeliveryBound()` now calls `BoundedWait.spin(until:)`. The two do not conflict: `AnswerDrivenRun` asks a question that crosses an actor and `spin` reads a semaphore, but each asks a question that cannot suspend for ever, again and again, until a ceiling. The yield phase does not damage the actor-crossing question; it only makes an answer that is already there arrive without a sleep. `spin` returns `Bool` (`@discardableResult`), so `conditionReached` no longer reads the condition a second time.

    **The same defect in a second file, removed.** `TurnCancellationTests.swift` carried a private copy: `spinYieldLimit = 100_000` and a private `spin(until:)`, used at 7 sites. Card `^h71b8yv` left it out of its scope. It is the same cause, thus the copy is deleted and the 7 sites call `BoundedWait.spin(until:)`.

    **Kept, because they are the reason the helper exists.**
    - The wait always ends: the deadline ends it, and `Task.sleep` that fails on cancellation becomes a yield, so cancellation never decides when a wait ends and never makes a hot loop.
    - The fault still reports through `Issue.record` with the same words, and the test proves the recorded issue names the label.
    - `awaitSignal`'s two steps are not collapsed. The non-suspending `availablePermits` reading stays before `wait()`, and the single-consumer precondition on the `enum BoundedWait` doc comment is unchanged, word for word.

    **Cost.** The main test target goes from 2.776 s to 5.04 s, because one new test waits out the full 5 s ceiling to prove that a condition which never holds ends the wait. The other 781 tests still finish inside that time.
  timestamp: 2026-08-10T19:18:06.822706+00:00
- actor: claude-code
  id: 01kzphss2xadd4xhpyfwxh698e
  text: |-
    ### implement — changed

    - evidence: 4 files — `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift` (wall-clock bound), `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift` (`AnswerDeliveryBound` deleted, polls through `BoundedWait.spin`), `Tests/FoundationModelsRouterTests/TurnCancellationTests.swift` (private 100000-hop copy deleted, 7 sites through `BoundedWait.spin`), `Tests/FoundationModelsRouterTests/BoundedWaitTests.swift` (new, 2 tests).
    - new bound: `ceilingNanoseconds` 5 s read from a `ContinuousClock` deadline, `yieldsBeforePolling` 1000 hops first, then `pollIntervalNanoseconds` 5 ms between readings. `spin` returns `Bool`, `@discardableResult`.
    - red first: both new tests failed against the old bound. The hop budget expired after 0.087 s idle, thus a signal that arrives at 0.4 s was lost.
    - A/B under load (96 busy processes on 32 cores, load average 101): OLD bound — the late signal test fails after 0.121 s; NEW bound — every test passes, the late signal is seen at 0.410 s, the false condition ends at 5.001 s with the named issue.
    - under load, final tree: the 9 `HumanWaitGate` tests (the 3 named among them) pass in 0.015 s; the whole suite passes — 783/75 + 24/9 + 24/5, 0 failures, 1 known issue (the intended one).
    - idle: `swift test` green, 783 tests in 75 suites + 24 in 9 + 24 in 5, 0 failures. The only build warning is the SwiftPM `missing creator for mutated node` warning, which is present on HEAD as well.
    - `git diff -- Sources` is 0 bytes. `Scripts/check-doc-links.py`: 0 stale, 0 unresolved. No `swift format` run. No gated suite run. Nothing committed, nothing pushed.
    - next: `/review`.
  timestamp: 2026-08-10T19:18:41.501276+00:00
- actor: claude-code
  id: 01kzpj0pvgjhwpkr6nh6nbj58a
  text: |-
    ### test — green
    - evidence: `swift test` — Test run with 783 tests in 75 suites passed after 5.022 seconds with 1 known issue (the deliberate `withKnownIssue` in the new give-up test). Plus 24 tests in 9 suites, and 24 tests in 5 suites, both passing. 0 failures. Only warning line is a pre-existing SwiftPM plugin message about `mlx-swift_Cmlx.bundle` (a dependency resource bundle), unrelated to this change — no new warnings in the changed files.
    - three properties: (a) wait always ends — `spin(until:)` yields up to `yieldsBeforePolling` times, then loops checking the condition then the `ContinuousClock` deadline; `waitOnePollInterval()` falls back to `Task.yield()` when `Task.sleep` is cancelled, so a cancelled wait keeps looping to the deadline check instead of exiting early or hanging — confirmed by code read. (b) `conditionReached` records `Issue.record("\(label) was never observed inside the bound...")`, so the fault names the label — confirmed. (c) `awaitSignal` calls `signalArrived` (non-suspending `availablePermits` read via `spin`) strictly before `semaphore.wait()`; the enum doc comment still states the single-consumer precondition — confirmed.
    - AnswerDrivenRun unchanged: `finishesWithinDeliveryBound()` now calls `BoundedWait.spin(until:)`, whose ceiling (5_000_000_000 ns) and poll interval (5_000_000 ns) match the prior 5 s / 5 ms bound; the give-up path in `deliveredAnswer()` still calls `task.cancel()` and throws without awaiting `task.value` — confirmed.
    - `git diff -- Sources` is empty — confirmed (0 lines).
    - untracked file: `Tests/FoundationModelsRouterTests/BoundedWaitTests.swift` — needs `git add` at commit.
    - TurnCancellationTests: `git diff` shows the private `spinYieldLimit`/`spin(until:)` deletion and 7 mechanical call-site renames to `BoundedWait.spin(until:)`, with identical surrounding guard/`Issue.record`/`#expect` logic at each site — confirmed no rewrite.
  timestamp: 2026-08-10T19:22:28.592008+00:00
- actor: claude-code
  id: 01kzpjeen0vpw1e2kj0z5j7abn
  text: |
    ### review — clean
    - scope: `review sha HEAD~1..HEAD` (sha 7534466), task-mode
    - evidence: zero new findings; 9 validators attempted, 0 failed, 0 skipped; 0 prior findings items to check
    - no acronym-casing findings appeared, thus no waiver was necessary
    - next: none. Task moves to `done`.
  timestamp: 2026-08-10T19:29:58.944469+00:00
- actor: claude-code
  id: 01kzpjjpp0p3npfy9k5g00t5zv
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 files, no production code (`git diff -- Sources` empty). `BoundedWait.spin(until:)`'s bound is now a `ContinuousClock` deadline of `ceilingNanoseconds` (5 s): it yields for the first `yieldsBeforePolling` (1000) hops so a change behind a few suspensions still costs microseconds, then sleeps `pollIntervalNanoseconds` (5 ms) between readings until the deadline. `spin` returns `Bool` (`@discardableResult`), so `conditionReached` no longer re-reads the condition.
    - **Three copies became one.** `AnswerDeliveryBound` deleted — `AnswerDrivenRun.finishesWithinDeliveryBound()` now calls `BoundedWait.spin(until:)` with its 5 s / 5 ms behaviour unchanged and its give-up path still not awaiting the run. `TurnCancellationTests`' private `spinYieldLimit = 100_000` and `spin(until:)` deleted across 7 sites — that was the duplication noted as out-of-scope in `^h71b8yv`, removed here because it is the same cause. Net −4 lines across three files while adding the deadline.
    - New `Tests/FoundationModelsRouterTests/BoundedWaitTests.swift` tests the bound itself.
    - **Why the old bound was backwards**, per the review: a yield is cheap for the waiter, so 100,000 hops burned a near-fixed amount of the *waiter's own* CPU while the task that had to make the change queued for a core — more load meant a tighter effective wall-clock budget. Two mechanisms fix it, not one: the change of unit, and sleeping rather than yielding past hop 1000, which surrenders the slice to the task that must act. The second is independent of the unit and matters most under load.
    - **Proven under real load**, as the card demanded: 96 busy processes on 32 cores, load average 101. Old bound expired at 0.121 s and failed; new bound saw the late signal at 0.410 s and ended a genuinely false condition at 5.001 s with the named issue. Red-first established idle too — the old hop budget expired after 0.087 s. Under load the 9 `HumanWaitGate` tests, including the 3 named, pass in 0.015 s.
    - The observed 3.0–3.7 s failures were the time to burn the hop budget while spinning, NOT the time the change needed — so the real margin under the 5 s ceiling is wider than that ratio suggests.
    - test: green — 783/75 in 5.022 s (the deliberate give-up test registers as a known issue, not a failure), plus 24/9 and 24/5, 0 failures, no new warnings. The three load-bearing properties confirmed by code read: the wait always ends (a cancelled `Task.sleep` falls back to `Task.yield()` so the loop still reaches the deadline check — the ceiling is binding, not advisory); `conditionReached` records an issue naming the label; `awaitSignal`'s non-suspending `availablePermits` read stays strictly before `wait()`, with the single-consumer precondition still documented.
    - **Two deliberate accepted costs**: the suite is now 783/75 (was 781/74) from the two new tests, and the main target goes ~2.776 s → ~5.04 s because the give-up test waits out the SHIPPED 5 s ceiling. A test-only ceiling parameter was considered and rejected: it would prove that *some* bound terminates, not that the shipped one does, and the shipped value is what would hang CI.
    - commit: 7534466 — 6 files, +175/-88, local only. `BoundedWaitTests.swift` confirmed via `create mode 100644`.
    - review: clean — zero new findings. Engine: 9 validators, 0 failed.
    - **Two things named by the review, not filed, for a future call:** (1) the rejection of the test-only ceiling parameter is recorded here and in the commit message but NOT in `BoundedWaitTests.swift`, so a reader opening that file to trim suite time will not see it — one sentence in the file would fix that; (2) neither new test asserts an *upper* bound on elapsed time, so a deadline that never fired would hang rather than fail. That is not fixable in this repo: the test target sets no `.timeLimit` trait and SwiftPM offers no manifest-level way to add one, which is the reason `BoundedWait` exists. The suite completing at ~5.04 s demonstrates the deadline fires on every run.
    - next: task moved to done.
  timestamp: 2026-08-10T19:32:18.240930+00:00
position_column: done
position_ordinal: ff8180
title: '[Router] BoundedWait''s yield-count bound makes HumanWaitGateTests fail under machine load'
---
## What happened

A full `swift test` run failed with 6 issues in 3 tests. All 3 tests are in the suite "Human waits release the per-model generation gate, never the per-session turn lock" in `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift`:

- "awaitingUser with no turn in flight runs the body and releases nothing" — `HumanWaitGateTests.swift:904`, error `RunNeverFinished()`.
- "a turn ending while a human wait's re-acquire is in flight strands no permit: the model family keeps generating" — `HumanWaitGateTests.swift:817`, error `SignalNeverArrived()`.
- "a human wait overlapping a turn it is not part of leaves the gate at exactly one permit" — `HumanWaitGateTests.swift:738`, error `RunNeverFinished()`.

Each of the 6 issues comes from the same line: `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift:70`.

## Why it is a defect, not only bad luck

`BoundedWait.spin(until:)` gives a condition `yieldLimit` cooperative yields. `yieldLimit` is 100000 hops. The bound counts scheduler hops. It does not measure wall-clock time.

The doc comment on `yieldLimit` makes this claim: a state change that a test puts behind some task suspensions "always lands" inside the bound. That claim is not true when the machine has a heavy load. The task that must cause the state change can get very few time slices. The task that waits can then use all 100000 yields before the other task runs sufficiently. The wait then gives up, although the code is correct.

Thus the bound is a function of the load on the machine. A test that is correct can fail. This is the type of failure that makes a suite unreliable.

## Evidence

- The failure came in a full `swift test` run directly after a `periphery scan` and a `swift build --build-tests`. The machine had a heavy load.
- The immediately previous full run of the same code was green.
- The immediately subsequent full run of the same code was green: 781 tests in 74 suites, 24 in 9, 24 in 5.
- `swift test --filter HumanWaitGate` alone gives 9 tests in 1 suite, and the suite completes in 0.077 seconds. In the failed run the same 3 tests each took 3.0 to 3.7 seconds before they gave up.

The difference between 0.077 seconds and 3.7 seconds shows the starvation. The tests do not wait for a condition that is false. They wait for a condition that arrives too late for a bound that counts hops.

## What to do

Make the bound independent of the load on the machine. Do not simply increase `yieldLimit`: a larger count of hops still fails at a sufficiently heavy load, and it also makes each true failure slower.

Examine these options:

- Give the bound a wall-clock deadline as well as the hop count. End the wait when the condition holds. Report a fault only after the deadline passes.
- Wait on an event instead of a poll, if the observed value permits it.

Keep the properties that the existing doc comment gives as the reason for this helper:

- The wait must always end. `AsyncSemaphore.wait()` ignores cancellation, thus a bare wait can stop the full `swift test` run.
- A fault must report through `Issue.record` and name what did not happen.
- Do not collapse the two steps of `awaitSignal`. The reading of `availablePermits` must stay before the `wait()`.

## Acceptance Criteria

- [x] The bound of `BoundedWait` does not fail because of the load on the machine.
- [x] The 3 named tests pass when the machine has a heavy load. Put a load on the machine, then run the suite, to make the check.
- [x] A condition that is truly false still ends the wait, and still records an issue that names it.
- [x] `swift test` green.

## Notes

Found during work on `^vhjhaey`. That card changes comment lines only, thus it does not cause this failure. `git diff -- Sources` was 0 bytes for the full period.