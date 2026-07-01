---
comments:
- actor: wballard
  id: 01kwerp8tr2hbpyj805arfm35n
  text: |-
    Picked up (milestone 9). Research done. Design:
    - New `SessionKVCache` protocol (class-bound, Sendable) with `copy()`; `makeCache()` added as a requirement on `LoadedLLMContainer` with a default returning an inert cache (real MLX `KVCache.copy()` deferred to milestone 7 — live `ModelContainer.respond` already throws notWiredForLiveInference, so no MLX reachable without GPU; abstraction + stub-tested here).
    - Gates live on the shared `RoutedModel` handle (RoutedLLM is a typealias, can't add stored props to a specialization): `serialGate = AsyncSemaphore(value:1)` and `forkAdmissionGate = AsyncSemaphore(value: maxConcurrentForks)`. Router.makeRoutedLLM passes maxConcurrentForks.
    - `RoutedSessionActor` gains `cache`, `serialGate`, `forkAdmissionGate`, `holdsAdmissionPermit`. `generate` wraps body in `serialGate.withPermit`. `fork()` awaits admission permit, then builds child with parentId=self.id, cache=parent.cache.copy(), inherited grammar/instructions, holdsAdmissionPermit=true. `deinit` signals the admission gate iff it holds a permit; the child's cache dies with the actor (ARC) -> free.
    - Remove now-obsolete `SessionError.forkNotWiredUntilMilestone9` + the SessionChokepointTests.forkNotYetWired test (fork now wired).
    Tests deterministic via AsyncSemaphore waiterCount/availablePermits + a Mutex-based CacheCensus (synchronous births/copies/frees) — no sleeps for the core assertions.
  timestamp: 2026-07-01T11:58:05.656071+00:00
- actor: wballard
  id: 01kwesad1x8waeems9hnnwxfy6
  text: |-
    Implementation landed (TDD: wrote ForkConcurrencyTests first -> RED via missing SessionKVCache/gates/fork, then implemented -> GREEN).

    Results (export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer):
    - `swift test --filter ForkConcurrencyTests`: 5/5 pass (copy-on-fork+parentId, KV-free-on-release + parent unaffected, guided-fork grammar inheritance, serial-gate non-overlap+FIFO, fork-admission bound).
    - Full `swift test`: 88 tests + 1 gated suite, all pass. `swift build --build-tests`: zero warnings from changed files.

    Notes / design decisions worth recording for the next agent:
    - KV abstraction: `SessionKVCache` protocol (class-bound, Sendable, `copy()`); `makeCache()` added as a REQUIREMENT on `LoadedLLMContainer` (with a default returning `InertKVCache`) so a test stub can override it and dynamic-dispatch through `any LoadedLLMContainer`. Real MLX `KVCache.copy()` stays a documented milestone-7 seam (live `ModelContainer.respond` already throws notWiredForLiveInference; MLX not reachable without GPU).
    - Gates live on the shared `RoutedModel` (serialGate value 1; forkAdmissionGate value maxConcurrentForks) since RoutedLLM is a typealias and can't hold stored props on its own. The embedder inherits them unused (documented).
    - Serial gate: acquired via `wait()`/`defer signal()` inside `generate` (NOT `withPermit` — sending the closure into AsyncSemaphore tripped region isolation; wait/defer keeps the recording bracket in the actor's isolation region and pairs identically, no leak).
    - Admission permit released in the fork's `deinit` (only when holdsAdmissionPermit). KNOWN micro-ordering: ARC runs the deinit body (signal) before releasing the `cache` member (free), so a freed slot can admit a waiter before the releasing fork's KV is reclaimed — a transient K+1 during teardown. The plan only requires "freed when a fork is released", so this is acceptable; the admission-bound test asserts the ceiling via the parked-state (two admitted + third blocked on waiterCount), not a post-release high-water mark, to stay non-flaky.
    - Removed obsolete `SessionError.forkNotWiredUntilMilestone9` and SessionChokepointTests.forkNotYetWired.

    Left in `doing` for /review (adversarial double-check running).
  timestamp: 2026-07-01T12:09:05.341641+00:00
- actor: wballard
  id: 01kwesjsnvpehk193qxt1vxgzd
  text: |-
    Adversarial double-check: VERDICT PASS (no findings). Confirmed: makeCache() is a real protocol requirement (dynamic dispatch through `any LoadedLLMContainer` works, stub override hit); serial gate releases on return/throw/cancel and the FIFO test is deterministic (spins on availablePermits/waiterCount, no sleeps); admission permit is one-acquire/one-release with no suspension between acquire and child construction (cancellation cannot strand it); no retain cycle (profile held weakly via OwningProfileBox; deinit touches only Sendable/nonisolated state, cannot resurrect self); clean strict-concurrency build; no dangling refs to removed SessionError/forkNotYetWired. Ran `swift test --filter ForkConcurrencyTests` 8x — all green, no flakiness/hangs; full `swift test` 88+1 green.

    Work is done and GREEN; left in `doing` for /review.
  timestamp: 2026-07-01T12:13:40.411494+00:00
- actor: wballard
  id: 01kwet8jx7cn5hy8yr4r33yzd9
  text: |-
    Review finding resolved (Router.swift force-unwrap). Pulled review→doing. Replaced the two bare `generationContainers[.standard]!` / `[.flash]!` force-unwraps (the readback after the standard/flash download loop) with a single documented guard:

        guard let standardContainer = generationContainers[.standard],
              let flashContainer = generationContainers[.flash]
        else {
            preconditionFailure("download loop populates both .standard and .flash generation slots")
        }

    Behavior is identical (still a hard failure if the invariant is ever violated); intent is now documented and there is no bare `!`. Both Review Findings checkboxes flipped to [x]. Tests green: `swift test --filter ResolveTests` (8), `swift test --filter ForkConcurrencyTests` (5), full `swift test` (88 tests + 1 gated skip). Left in doing for /review.
  timestamp: 2026-07-01T12:25:34.375577+00:00
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5CYM8AFB1MBV7DR9KW83K
- 01KWC5GJM72ASQV4GKXSFPKFFG
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-07-01 07:15)

- [x] `Sources/FoundationModelsRouter/Router.swift:107` — Force unwrap `!` used in non-test code violates the no-force-unwrap rule. The rule explicitly prohibits force unwrap even when safe by construction—use guard with preconditionFailure instead to document the invariant clearly. Replace both lines 107–108 with: guard let standardContainer = generationContainers[.standard], let flashContainer = generationContainers[.flash] else { preconditionFailure("Both generation slots must be populated by the download loop") }.
- [x] `Sources/FoundationModelsRouter/Router.swift:108` — Force unwrap `!` used in non-test code violates the no-force-unwrap rule. Combine this with the preceding unwrap into a single guard statement for clarity and to satisfy the rule. Merge lines 107–108 into a single guard-let statement: guard let standardContainer = generationContainers[.standard], let flashContainer = generationContainers[.flash] else { preconditionFailure(...) }.

Resolved 2026-07-01: replaced the two bare force-unwraps (the readback after the standard/flash download loop) with a single documented `guard let ... else { preconditionFailure(...) }`. Behavior identical; no bare `!`. `swift test` green (88 tests + gated skip).
