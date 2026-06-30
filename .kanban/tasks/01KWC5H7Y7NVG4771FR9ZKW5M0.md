---
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5CYM8AFB1MBV7DR9KW83K
- 01KWC5GJM72ASQV4GKXSFPKFFG
position_column: todo
position_ordinal: 8d80
title: Session fork + per-model concurrency gates (milestone 9)
---
## What
The `fork()` primitive over the KV cache plus the two concurrency gates. Plan "Sessions & KV cache", "Concurrency". Builds on the access layer (milestone 5) and the fair async semaphore.

- `Sources/FoundationModelsRouter/Session/RoutedSession.swift` (fork):
  - `func fork(workingDirectory: URL?) -> RoutedSession`: child's cache **begins as a copy of the parent's** via `KVCache.copy()` (inherits the prefilled prefix's compute, then diverges). Child takes `routerID`, the recorder, and `parentID = self.id`; transcript nests under the parent regardless of `workingDirectory` (full nesting is milestone 10, but `parentID` is set here). A guided session's fork inherits the grammar.
  - A session's cache **dies with the session** (ARC) — releasing a fork frees its KV; the fork retains the profile so resident models stay alive.
- `Sources/FoundationModelsRouter/` concurrency gates (built on `AsyncSemaphore`):
  - **Per-model serial gate** (value 1, FIFO): concurrent `respond()` on one `RoutedLLM` (including from forks of the same model) queue rather than interleave — MLX generation isn't safe to interleave and the GPU runs one stream. Each `RoutedLLM` owns a serial gate.
  - **Fork admission gate** (value `maxConcurrentForks` from `Router`): at most that many fork sessions in flight; `fork()` past the limit awaits a free slot, freed when a fork is released — capping the K× prefix-KV cost of `copy()`.

## Acceptance Criteria
- [ ] A fork's cache starts equal to the parent's prefix (assert the prefix isn't recomputed — verified for real in the gated integration suite; unit-assert `KVCache.copy()` is invoked and `parentID == parent.id`).
- [ ] Concurrent `respond()` calls on one model never overlap (per-model serial gate) and run FIFO.
- [ ] At most `maxConcurrentForks` forks run concurrently; the next `fork()` awaits until one is released (assert via an atomic concurrency counter).
- [ ] Releasing a fork frees its KV cache (assert via a cache-free spy); the parent's cache is unaffected.
- [ ] A guided session's fork still constrains output to the inherited grammar.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ForkConcurrencyTests.swift` (Swift Testing) with stub model + spies: serial-gate non-overlap + FIFO; fork-admission bound; copy-on-fork + parentID; KV free on fork release; grammar inheritance.
- [ ] Run `swift test --filter ForkConcurrencyTests` — all pass.

## Workflow
- Use `/tdd` — write failing serial-gate, admission-bound, and copy/free tests first.