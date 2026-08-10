---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: SessionOutboxTests and HumanWaitGateTests hang instead of failing when their wakeup path breaks
---
Found while working `^6fszv54`, which bounded every test that awaits a **delivered elicitation answer**. Two further families of unbounded wait sit outside that card's cause and are still live.

The `FoundationModelsRouterTests` target sets no `.timeLimit` trait anywhere, and SwiftPM offers no manifest-level way to set one, so any await that never completes hangs the whole `swift test` run rather than failing one test.

## SessionOutboxTests

`SessionOutbox.nextEvent()` parks on a continuation that only a later `post`/`enqueue` resumes. Three tests await it with no bound, and the file carries **no** bounded helper at all — its only synchronisation is a fixed 20 ms sleep.

- [ ] `nextEventSuspendsUntilPost` — `await waiter.value`
- [ ] `nextEventResumesOnEnqueuedPrompt` — `await waiter.value`
- [ ] `nextEventReturnsImmediatelyWhenNonEmpty` — awaits `outbox.nextEvent()` on the test task itself; the comment `// Must not hang: the outbox is already non-empty.` is the whole safety mechanism
- [ ] `drainIsRaceFreeWithConcurrentPost` — a `while true` drain loop with no iteration cap, so a drain that never empties spins forever

## HumanWaitGateTests

Every `await <AsyncSemaphore>.wait()` on the test task is unbounded: `AsyncSemaphore.wait()` uses `CheckedContinuation<Void, Never>` and ignores cancellation by design, so nothing can break such a wait. The file already carries the `spin(until:)` / `followUpTurnCompletes(on:observer:prompt:)` hatch modelled in `TurnCancellationTests`, which covers the *stranded generation permit* failure mode — but not a human-wait body that never runs.

- [ ] Decide whether the semaphore waits can be bounded at all, or whether the gate signal has to be observed some other way
- [ ] Give the `await <task>.value` sites the same treatment the elicitation suites now have

## Acceptance criteria

- [ ] Prove each fix the way `^6fszv54` did: break the wakeup path deliberately, confirm the suite fails fast with a readable message instead of hanging, then restore and confirm green. Always run the broken experiment under a hard shell timeout.
- [ ] Reuse the existing escape hatch shape rather than inventing another mechanism — `TurnCancellationTests.spin(until:)` plus a recorded issue and a give-up, or the shared `AnswerDrivenRun` helper `^6fszv54` added, whichever fits.
- [ ] `swift test` stays green with no new warnings.

## Notes

- Do NOT run gated integration tests (`FM_ROUTER_INTEGRATION_TESTS=1`) — they load a 27B model.
- Never run `swift format` / `swiftformat` in this repo. #phase-1