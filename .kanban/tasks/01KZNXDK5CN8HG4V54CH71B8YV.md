---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzp147mngyytv9p4bh0427w6
  text: |-
    Research + decision on the HumanWaitGateTests half.

    **The semaphore waits CAN be bounded.** Not by bounding `AsyncSemaphore.wait()` itself — that is genuinely impossible, it suspends on `CheckedContinuation<Void, Never>` and ignores cancellation by design, so no cancel, no trait and no other task can break it. What IS breakable is the *observation*: `AsyncSemaphore.availablePermits` answers "has it been signalled yet?" without suspending, so a bounded spin over that reading ends whether or not the signal ever comes. Entering `wait()` only once a permit is provably present is then safe, because that `wait()` takes the permit immediately instead of suspending.

    The precondition is single-consumer. Every semaphore the test task waits on in this suite has exactly one signaller (the mid-turn hook) and one waiter (the test task), so nobody can take the observed permit in between. That precondition is written into the helper's doc comment.

    Shape reused, not invented: `TurnCancellationTests.spin(until:)` — bounded wait, recorded issue, give up. The spin plus the two semaphore entry points now live in one shared place, `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift`, so `SessionOutboxTests` uses it without adding a third copy of the spin loop. `HumanWaitGateTests`'s own private `spin(until:)`/`spinYieldLimit` are deleted in favour of it. `TurnCancellationTests` is left alone — out of this card's scope.

    `AnswerDrivenRun` was considered and NOT reused: its recorded message is answer-specific ("no answer ever reached X … the inbound answer route is broken"), which would be an actively wrong diagnostic for an outbox wakeup or a stalled generation gate.

    **Discovery that widened the work.** The first fault injection (`awaitingUser` taking `turnLock`) still hung the suite after the card's two named families were bounded. Three further test-task awaits of session work were the cause, and none of them is literally an `AsyncSemaphore.wait()` or an `await <task>.value`:
    - `throwingFromAHumanWaitReAcquiresTheGateAndPropagates` — `await #expect(throws:) { try await session.respond(to: "throwing") }`, a bare turn await whose tool waits on a person
    - `waitOverlappingAnotherTurnDoesNotInflateTheGate` tail — `await session.awaitingUser { … }` on the test task
    - `awaitingUserWithNoTurnInFlightReleasesNothing` — `await session.awaitingUser { 42 }` on the test task

    All three are now run as their own task and observed under the same bound. Without them the behavioural acceptance criterion is not met, so they were treated as in scope.

    **Note for the next agent:** `Task.value` is declared separately for `Failure == Never`, so `completedRun` cannot be one generic function over `Failure`; it is two overloads sharing `finished(_:when:)`. Do not "simplify" them into one — it does not compile.
  timestamp: 2026-08-10T14:27:18.293686+00:00
- actor: claude-code
  id: 01kzp14n1v71bfp1cmhayge4ns
  text: |-
    ### implement — changed
    - evidence: 3 files — `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift` (new), `Tests/FoundationModelsRouterTests/SessionOutboxTests.swift`, `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift`. `git diff -- Sources` is EMPTY; no production change was needed.

      **Fault injection, half 1 (SessionOutbox).** Fault: `wakeUp()` deleted from `SessionOutbox.post(_:)`.
      - before the fix: `timeout 120 swift test --filter SessionOutboxTests` produced NO test output at all and was killed at 120.03 s (exit 124).
      - after the fix: the same run failed in 8.5 s with `the nextEvent() wait for a post was never signalled, so the code that signals it never ran` plus `Expectation failed: await waiter.wokeUp()`. 1 test failed, 19 passed.
      - fault reverted, suite green.

      **Fault injection, half 2 (HumanWaitGate).** First fault tried: `awaitingUser` takes `turnLock` before its body. Before the fix: no output, killed at 120.04 s (exit 124). After bounding only the card's two named families it STILL hung at 120.06 s — that observation is what found the three extra unbounded test-task awaits (see the previous comment). Second fault: `awaitingUser` takes `generationGate` instead of releasing it, so the human-wait body never runs.
      - after the fix: `timeout 180 swift test --filter HumanWaitGateTests` failed in 14.3 s (0.70 s of test time), all 9 tests failing with readable messages — e.g. `the gate release inside sessionA's human wait was never signalled, so the code that signals it never ran`, `the inner human wait being entered was never signalled…`, `Caught error: SignalNeverArrived()`, `Caught error: RunNeverFinished()`. 18 issues, zero hangs.
      - fault reverted, suite green.

      **Green run.** `swift test` — 778 tests in 72 suites, 24 in 9 suites, 24 in 5 suites, 0 failures. Identical to the pre-change baseline. The only warning is the pre-existing SwiftPM `missing creator for mutated node` build-system line, present in the baseline too; `swift build --build-tests` reports no compiler warning.
    - next: `/review`
  timestamp: 2026-08-10T14:27:32.027684+00:00
- actor: claude-code
  id: 01kzp21m333qtby7m83e954249
  text: |
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (9acf971), task-mode
    - evidence: 1 finding, 1 confirmed, 0 refuted, 9 validators attempted, 0 failed, 0 skipped — Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:306
    - checked: `finished()` is NEW in this commit (absent from HEAD~1), so the "do not refactor pre-existing tests" exception does not apply. The finding stands.
    - waivers: none applied; the engine raised no acronym-casing finding this pass.
    - noted: the single-consumer precondition IS documented at the helper (BoundedWait.swift, the enum doc comment names it as "The one precondition").
    - next: extract the shared spin-recheck-record pattern into `BoundedWait.conditionReached(_:when:)` and have `finished()` call it. Remove the duplicated algorithm across the whole file, not only the one site named.
  timestamp: 2026-08-10T14:43:21.315841+00:00
- actor: claude-code
  id: 01kzp22yzw12r1gfn0pywawfqs
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files. New shared `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift` (`spin(until:)` extracted from TurnCancellationTests' hatch, same shape/constant, plus `signalArrived`/`awaitSignal`); SessionOutboxTests' three `nextEvent()` waits go through an `OutboxWaiter` and the `while true` drain loop gains a `totalEvents + 1` cap plus an `emptied` assertion; HumanWaitGateTests' private `spin`/`spinYieldLimit` removed in favour of the shared helper, 8 semaphore waits through `awaitSignal`, `await <task>.value` through `completedRun`/`completedTurn`. `git diff -- Sources` empty.
    - **The semaphore decision.** `AsyncSemaphore.wait()` cannot be bounded — it suspends on `CheckedContinuation<Void, Never>` and ignores cancellation by design. But `availablePermits` answers "has it been signalled?" WITHOUT suspending, so a bounded spin over that always terminates, and entering `wait()` only once a permit is provably present cannot suspend. Valid because each such semaphore has one signaller and one waiter — verified individually at all 8 sites (gateFreed 494, insideWait 676, innerEntered 727, inTurn 765, waitEntered 782, inTurnA 855, waitEntered 871, inTurnB 877). The precondition is documented in the helper's own doc comment, so a future author adding a second waiter is warned.
    - **Scope widened deliberately and reported.** After bounding the two named families the injected fault STILL hung (an intermediate 120.06 s run proved it). Three further test-task awaits were the cause — a bare `try await session.respond(...)` inside `#expect(throws:)` and two `await session.awaitingUser { … }` calls — none a semaphore wait or a `task.value`. Bounded too, because the behavioural criterion is not met otherwise.
    - test: green — swift test 778/72 + 24/9 + 24/5, 0 failures, no new warnings. `git diff -- Sources` empty (both injected faults reverted). Drain cap `totalEvents + 1` confirmed a genuine finite bound (each non-terminal iteration consumes ≥1 of 200 distinct events).
    - commit: 9acf971 — 7 files, +455/-89, local only. BoundedWait.swift confirmed present via `git show --stat HEAD`.
    - review: findings — Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:306. `finished()` reimplements `BoundedWait.signalArrived()`'s algorithm (spin until a condition holds, re-check, record an issue on failure); extract a general `conditionReached(_:when:)` onto BoundedWait and route `finished()` through it. Confirmed in scope: `finished()` does not exist in HEAD~1, so it is new code and the pre-existing-test exception does not shield it. Engine: 9 validators, 0 failed. No duplication finding against AnswerDrivenRun.
    - Timings for the record: half 1 no output at 120 s (killed, exit 124) → readable failure in 8.5 s; half 2 no output at 120 s → all 9 tests fail in 0.70 s of test time.
    - next: iteration 2 — extract `conditionReached`, and remove the duplicated algorithm from the whole file rather than only line 306.
  timestamp: 2026-08-10T14:44:05.244013+00:00
- actor: claude-code
  id: 01kzp2fpdehr6ne0ytrs1nfgmq
  text: |-
    Iteration 2 — the file-wide sweep for the duplicated spin/re-check/record algorithm.

    **What the sweep found in `HumanWaitGateTests.swift`.** Two sites carried it, not one:
    - `finished(_:when:)` — the site the finding names. Now one line: `BoundedWait.conditionReached("the end of \(label)", when: condition)`.
    - `followUpTurnCompletes(on:observer:prompt:)` — the same algorithm minus the `Issue.record`: `BoundedWait.spin(until:)`, re-check `observer.exited.contains(prompt)`, cancel and give up. It now observes through `conditionReached` too, so a follow-up turn that never reaches the model records a named issue instead of only returning `false` for the caller's `#expect` to report.

    The five remaining bare `BoundedWait.spin(until:)` calls in the file are NOT copies of the algorithm and were left alone. Each is an ordering barrier before an assertion the test itself makes (`humanGate.waiterCount == 1` before reading the transcript, `turnLock.waiterCount == 1` before reading `lastFork`, and so on). They already call the shared `spin` primitive, so no algorithm is duplicated there — only the primitive is reused, which is the point of the primitive.

    **`SessionOutboxTests.swift` — nothing else.** `OutboxWaiter.wokeUp()` already delegates to `BoundedWait.signalArrived`. The drain loop is a different mechanism — a `totalEvents + 1` iteration cap with `#expect(emptied, …)` — not a spin over a condition.

    **`Helpers/AnswerDrivenRun.swift` — checked, deliberately not converted.** `finishesWithinDeliveryBound()` is a wall-clock poll: `Task.sleep(pollIntervalNanoseconds)` under a 5 s `ceilingNanoseconds`, not a cooperative yield spin. Its own doc states why — the answer crosses an actor from whichever task delivers it, so the wait has to survive a loaded machine running the whole suite in parallel. Routing it through `conditionReached` would swap that wall-clock ceiling for a scheduler-hop bound the doc argues against, so it is a different algorithm for a stated reason, not a copy. The review engine raised no duplication finding against it either.

    **Semaphore invariant preserved.** `signalArrived` is now `conditionReached(label, when: { semaphore.availablePermits > 0 })`. The observed reading is still the non-suspending `availablePermits`, and the enum's own doc comment still carries the single-consumer precondition word for word ("The one precondition is that the semaphore has a single consumer: the test task doing the observing. Nobody else may take the permit between the reading and the `wait()`."). `signalArrived`'s doc now names that dependency explicitly, so the link from the reading to the precondition is written down rather than inferred.

    **Diagnostic wording changed, on purpose.** One message now serves every caller: `"\(label) was never observed inside the bound, so the code that makes it happen never ran"`. `signalArrived` passes its label through unchanged, so its callers' labels still read correctly; `finished` composes `"the end of \(label)"` so a run label reads as an end rather than as an event.

    Fault injection was NOT re-run — both experiments are already recorded above (no output at 120 s before the fix, readable failures in seconds after). This iteration changes only which function records the issue, not whether one is recorded.
  timestamp: 2026-08-10T14:51:02.446518+00:00
- actor: claude-code
  id: 01kzp2g0fgq3rv3bs2he945qf0
  text: |-
    ### implement — changed
    - evidence: 2 files — `Tests/FoundationModelsRouterTests/Helpers/BoundedWait.swift` (+ `conditionReached(_:when:)`; `signalArrived` now calls it), `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift` (`finished(_:when:)` and `followUpTurnCompletes(on:observer:prompt:)` now call it). 33 insertions, 17 deletions. `git diff -- Sources` is EMPTY — both earlier injected faults stay reverted.
    - sweep: 2 sites in `HumanWaitGateTests.swift`, nothing else in `SessionOutboxTests.swift`, and `Helpers/AnswerDrivenRun.swift` checked and left (wall-clock poll, a different bound with a documented reason). The 5 bare `BoundedWait.spin(until:)` calls are ordering barriers, not copies.
    - invariant: the single-consumer precondition doc comment on `enum BoundedWait` is unchanged, and `signalArrived` still observes the non-suspending `availablePermits` reading.
    - test: `swift build --build-tests` clean; `swift test` — 778 tests in 72 suites, 24 in 9 suites, 24 in 5 suites, 0 failures. The only warning is the pre-existing SwiftPM `missing creator for mutated node` build-system line.
    - next: `/review`
  timestamp: 2026-08-10T14:51:12.752671+00:00
- actor: claude-code
  id: 01kzp2pk105bga4bcwpe0nfqvw
  text: |-
    ### test — green
    - evidence: `swift test` — 778 tests/72 suites, 24 tests/9 suites, 24 tests/5 suites, all passed, 0 failures, 0 skipped. Only warning is the pre-existing `mlx-swift_Cmlx.bundle` baseline line; no new warnings.
    - `git diff -- Sources` is empty (0 lines) — no production code changed.
    - `BoundedWait.swift` doc comment on `enum BoundedWait` still states the single-consumer precondition: "the semaphore has a single consumer: the test task doing the observing. Nobody else may take the permit between the reading and the `wait()`." `signalArrived` still reads the non-suspending `AsyncSemaphore.availablePermits` via `conditionReached(label, when: { semaphore.availablePermits > 0 })` — no suspending wait introduced.
    - `followUpTurnCompletes` now routes through `BoundedWait.conditionReached`, which calls `Issue.record("\(label) was never observed inside the bound, so the code that makes it happen never ran")` on the give-up path, naming "the follow-up turn \(prompt) leaving the model" — no longer fails silently.
    - `conditionReached` is built directly on `spin(until:)`, whose bound `yieldLimit = 100_000` is unchanged and finite.
    - `Tests/FoundationModelsRouterTests/Helpers/AnswerDrivenRun.swift` has an empty diff (0 lines) — untouched. The five bare `BoundedWait.spin(until:)` calls in `HumanWaitGateTests.swift` remain (verified count: 5), still used as ordering barriers rather than forced through `conditionReached`.
    - next: ready for review/commit
    task: ^h71b8yv
  timestamp: 2026-08-10T14:54:48.352141+00:00
position_column: doing
position_ordinal: '80'
title: SessionOutboxTests and HumanWaitGateTests hang instead of failing when their wakeup path breaks
---
Found while working `^6fszv54`, which bounded every test that awaits a **delivered elicitation answer**. Two further families of unbounded wait sit outside that card's cause and are still live.

The `FoundationModelsRouterTests` target sets no `.timeLimit` trait anywhere, and SwiftPM offers no manifest-level way to set one, so any await that never completes hangs the whole `swift test` run rather than failing one test.

## SessionOutboxTests

`SessionOutbox.nextEvent()` parks on a continuation that only a later `post`/`enqueue` resumes. Three tests await it with no bound, and the file carries **no** bounded helper at all — its only synchronisation is a fixed 20 ms sleep.

- [x] `nextEventSuspendsUntilPost` — `await waiter.value`
- [x] `nextEventResumesOnEnqueuedPrompt` — `await waiter.value`
- [x] `nextEventReturnsImmediatelyWhenNonEmpty` — awaits `outbox.nextEvent()` on the test task itself; the comment `// Must not hang: the outbox is already non-empty.` is the whole safety mechanism
- [x] `drainIsRaceFreeWithConcurrentPost` — a `while true` drain loop with no iteration cap, so a drain that never empties spins forever

## HumanWaitGateTests

Every `await <AsyncSemaphore>.wait()` on the test task is unbounded: `AsyncSemaphore.wait()` uses `CheckedContinuation<Void, Never>` and ignores cancellation by design, so nothing can break such a wait. The file already carries the `spin(until:)` / `followUpTurnCompletes(on:observer:prompt:)` hatch modelled in `TurnCancellationTests`, which covers the *stranded generation permit* failure mode — but not a human-wait body that never runs.

- [x] Decide whether the semaphore waits can be bounded at all, or whether the gate signal has to be observed some other way
- [x] Give the `await <task>.value` sites the same treatment the elicitation suites now have

## Acceptance criteria

- [x] Prove each fix the way `^6fszv54` did: break the wakeup path deliberately, confirm the suite fails fast with a readable message instead of hanging, then restore and confirm green. Always run the broken experiment under a hard shell timeout.
- [x] Reuse the existing escape hatch shape rather than inventing another mechanism — `TurnCancellationTests.spin(until:)` plus a recorded issue and a give-up, or the shared `AnswerDrivenRun` helper `^6fszv54` added, whichever fits.
- [x] `swift test` stays green with no new warnings.

## Notes

- Do NOT run gated integration tests (`FM_ROUTER_INTEGRATION_TESTS=1`) — they load a 27B model.
- Never run `swift format` / `swiftformat` in this repo.

## Review Findings (2026-08-10 09:38)

- [x] `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift:306` — `finished()` reimplements the identical algorithm that `BoundedWait.signalArrived()` implements: spin until a condition holds, re-check it, record an issue if it fails. The pattern is domain-independent and should be extracted to a shared `BoundedWait` helper to avoid duplication. Add a general-purpose `static func conditionReached(_ label: String, when condition: @Sendable () async -> Bool)` to `BoundedWait` that encapsulates this pattern once, and have `finished()` call it. This avoids duplicating the algorithm and makes the pattern available for reuse elsewhere. #phase-1