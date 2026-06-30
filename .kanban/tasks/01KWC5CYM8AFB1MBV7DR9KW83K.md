---
comments:
- actor: wballard
  id: 01kwcwvh4jhmk11sc8f10w83wb
  text: |-
    Implemented AsyncSemaphore (TDD). RED first: wrote Tests/FoundationModelsRouterTests/AsyncSemaphoreTests.swift, confirmed compile-fail "cannot find 'AsyncSemaphore'". Then GREEN: Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift.

    Design: `public final class AsyncSemaphore: Sendable` backed by `Synchronization.Mutex<State>` (State = permits + FIFO waiters array + monotonic id). wait() does an atomic check-and-suspend under one lock via withCheckedContinuation (take permit OR enqueue, never both; resume exactly once). signal() hands the freed permit directly to the FIFO front (removeFirst) or bumps the count; resume happens outside the lock. withPermit is `rethrows` with `defer { signal() }`.

    Cancellation: wait() is non-throwing (required so withPermit can be rethrows), so acquisition is not abandoned mid-flight (doing so would corrupt the permit count or strand a holder). Documented as deliberate; paired wait/signal in withPermit keeps the queue drained and leak-free. Continuations resumed exactly once.

    Tests deterministic (no sleeps): max-concurrency via actor counter; FIFO/capacity made deterministic by spinning on internal `waiterCount`/`availablePermits` observability hooks + Task.yield until a known state. Added those two internal (non-public) properties for testability/observability.

    Results: `swift test --filter AsyncSemaphoreTests` = 4/4 pass. Full `swift test` = 24 pass, 1 gated skip. Left in doing.
  timestamp: 2026-06-30T18:32:23.442341+00:00
- actor: wballard
  id: 01kwcx8atnta8qwexhq4tqk04b
  text: |-
    Addressed advisory double-check (verdict REVISE) findings:
    1. (Medium) Added cancellation test "a cancelled parked waiter still acquires in turn and strands no one": value 1, hold permit, park two waiters (first/second), cancel the front while parked, then signal the chain. Asserts FIFO preserved (order [0,1]), neither task stranded, and exact accounting (availablePermits==1, waiterCount==0 — no leak/over-release). Directly exercises the documented non-interrupting cancellation contract.
    2. (Low) Removed dead `Suspension.id`/`State.nextID`; FIFO is carried purely by array position. `waiters` is now `[CheckedContinuation<Void, Never>]` and the doc no longer implies the id orders anything.

    Verification: `swift test --filter AsyncSemaphoreTests` = 5/5, green on 3 consecutive runs (no flake). Full `swift test` = 25 tests pass + 1 gated integration skip, zero warnings. Task left in doing, ready for /review.
  timestamp: 2026-06-30T18:39:22.965190+00:00
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: doing
position_ordinal: '80'
title: Fair async FIFO semaphore primitive
---
## What
The single concurrency primitive both gates in the plan are built on (plan "Concurrency"): an await-based, fair (FIFO) async semaphore — NOT a thread-blocking `DispatchSemaphore`. Used at value 1 for the per-model serial gate and value `maxConcurrentForks` for fork admission.

- `Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift`:
  - `actor AsyncSemaphore` (or a `Sendable` final class with internal locking) with `init(value: Int)`.
  - `func wait() async` — suspends FIFO when no permits; `func signal()` — releases one waiter in arrival order.
  - A scoped helper `func withPermit<T>(_ body: () async throws -> T) async rethrows -> T` that waits, runs, and signals in `defer` (so cancellation/throw can't leak a permit).
  - Fairness: waiters resume strictly in the order they suspended.

## Acceptance Criteria
- [ ] With `value: 1`, two concurrent `withPermit` bodies never overlap (serialized).
- [ ] With `value: N`, at most N bodies run concurrently; the N+1th awaits until one signals.
- [ ] Waiters are released in FIFO order.
- [ ] A throwing body still releases its permit (no permit leak).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/AsyncSemaphoreTests.swift` (Swift Testing): assert max concurrency via an atomic counter under fan-out; assert FIFO release order; assert permit released after a thrown error.
- [ ] Run `swift test --filter AsyncSemaphoreTests` — all pass.

## Workflow
- Use `/tdd` — write failing concurrency-bound and FIFO-order tests first.