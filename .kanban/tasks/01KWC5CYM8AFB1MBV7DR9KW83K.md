---
depends_on:
- 01KWC5B8YQP4VJ14KQ64BDCXJS
position_column: todo
position_ordinal: '8580'
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