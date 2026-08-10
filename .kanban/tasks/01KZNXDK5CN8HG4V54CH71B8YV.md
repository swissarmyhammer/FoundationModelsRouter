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
- Never run `swift format` / `swiftformat` in this repo. #phase-1