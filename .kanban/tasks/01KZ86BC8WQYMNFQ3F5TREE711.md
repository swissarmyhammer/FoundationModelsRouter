---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz8kzke800naww5ysh0y70r9
  text: |-
    Research / root-cause diagnosis — verdict: TEST-SIDE race, product is correct.

    Product ordering is deterministic: `RoutedSessionActor.awaitingUser(_:)` calls `beginHumanWait()` synchronously BEFORE running the body, and `beginHumanWait()` releases the generation permit before returning (Sources/FoundationModelsRouter/Session/RoutedSession.swift). So by the time the test's wait body runs (`humanGate.wait()`), the gate is provably free. This matches the observed failure signature: `#expect(generationGate.availablePermits == 1)` PASSED in the failing run; only `exited == ["b"]` failed.

    The flake mechanism: the test observed B's turn completion through `spin(until:)` — a bounded loop of `spinYieldLimit` (100,000) `Task.yield()`s on the MainActor — as a proxy for "B's whole turn ran". During a full parallel `swift test` (721 tests, suites run concurrently on the cooperative pool), the pool is saturated: `Task.yield()` on the MainActor is cheap, so the loop can burn its 100k yields in milliseconds while `taskB`'s actor hops (turnLock acquire, gate acquire, backend, observer) are starved. Spin exhausts, `exited == []`, expectation fails. The first spin (`humanGate.waiterCount == 1`) has the same hazard class.

    Fix (test only): replace both scheduling-order spins with event waits — (1) a `gateFreed` semaphore signalled from inside the `awaitingUser` body (matches the suite's existing `insideWait`/`waitEntered` idiom), resuming the test at a point where the gate release has provably happened; (2) await `taskB.value` outright before asserting `exited`, guarded by the just-proven-free gate so the regression world (gate still held) fails the permits expectation and skips the await instead of deadlocking the suite.

    The suite's remaining `spin(until:)` uses wait on conditions with no test-visible event (a waiter appearing on a product-internal lock) and involve a single suspension rather than a whole turn; they stay.
  timestamp: 2026-08-05T09:27:27.432123+00:00
- actor: claude-code
  id: 01kz8m9mz3prgnwd620q8ggkz0
  text: |-
    Implementation landed — test-only change in Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift, test `humanWaitLetsAnotherSessionOnTheSameModelGenerate`:

    - First spin (`humanGate.waiterCount == 1`) replaced by a `gateFreed` semaphore signalled from inside the `awaitingUser` body. Since `awaitingUser` runs `beginHumanWait()` synchronously before the body and that releases the generation permit, `await gateFreed.wait()` resumes the test only after the gate release provably happened — no scheduler-hop bound. `humanGate.signal()` later is safe even if A has not yet suspended on `humanGate` (AsyncSemaphore banks the permit).
    - Second spin (`exited.contains("b")`) replaced by awaiting `taskB.value` outright, guarded by `gateFreeDuringWait` (the just-asserted permits==1). Correct product: gate free + A's re-acquire parked on humanGate, so B's turn completes deterministically and `exited == ["b"]` is read after a finished turn. Regressed product: the permits expectation has already failed, the await is skipped, and the tail (`humanGate.signal()` → taskA → taskB) unwinds without hanging the suite.
    - No product code touched. The suite's other `spin(until:)` uses remain — they wait on conditions with no test-visible event (waiters appearing on product-internal locks), one suspension deep, and fail visibly on exhaustion.

    Determinism proof:
    - `swift test --filter HumanWaitGateTests` — green (9 tests).
    - 15 consecutive loop iterations of `swift test --filter HumanWaitGateTests` — all 15 green.
    - Full `swift build` — complete, no compiler warnings.
    - Full `swift test` — 735 tests in 69 suites passed (+ 20/8 and 12/4 auxiliary runs passed); only the pre-existing environment-gated real-model suites skipped, same as the card's green baseline.
    - `review working` — 0 findings.
  timestamp: 2026-08-05T09:32:56.675112+00:00
- actor: claude-code
  id: 01kz8mn37j73b00p9g9w9zzrfz
  text: |-
    Double-check (adversarial verifier) returned REVISE with two findings; both fixed:

    Finding 1 — "Comment asserts a hang-freedom property the guard does not deliver": the test comment (and my earlier card comment) claimed the regressed world "lets the tail unwind it" / "the tail unwinds without hanging the suite". That claim is false for one plausible regression shape: if `releaseGenerationPermit()` were dropped from `beginHumanWait` while `humanWaitLenderTurnId = lender` survived, `endHumanWait` would unconditionally `await acquireGenerationPermit()` on a zero-permit gate whose queue already holds taskB, and `try await taskA.value` would hang — a pre-existing property, identical in the old code, not introduced by this diff. CORRECTION to the earlier implementation comment: the `if gateFreeDuringWait` guard guarantees only that the newly added `taskB.value` await introduces no new hang path in a regressed world; the tail's own awaits behave exactly as they always did. The test comment now says exactly that and no more.

    Finding 2 — "Acceptance criteria left unchecked": all three boxes in the card description are now ticked via `update task`, with tags re-supplied (#router-first, #flaky-test) and re-verified intact per the known update-task caveat.

    The verifier also independently reproduced the determinism claim: 5 consecutive full parallel `swift test` runs, all green (735/69 + 20/8 + 12/4), and confirmed release-before-body in `awaitingUser`/`beginHumanWait` and permit banking in `AsyncSemaphore` (signal-before-wait loses no wakeup).
  timestamp: 2026-08-05T09:39:11.730556+00:00
- actor: claude-code
  id: 01kz8mt0cytk7tvyfm9zzy784g
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift (test-only; no product code touched). Root cause: test-side race — bounded yield spin (`spin(until:)`, 100k MainActor yields) used as a proxy for B's turn completion could exhaust under full-suite parallel scheduler load; product gate release order verified correct. Fix: event-based sync (`gateFreed` semaphore signalled inside the `awaitingUser` body) plus a direct guarded `taskB.value` await before asserting `observer.exited`. Proof: `swift test --filter HumanWaitGateTests` green 15/15 loop iterations (+5 independent full parallel runs by the verifier); full `swift build` clean; full `swift test` 735/69 + 20/8 + 12/4 all passed, exit 0; `review working` 0 findings; double-check REVISE findings both fixed.
    - next: ready for /review
  timestamp: 2026-08-05T09:41:52.670777+00:00
- actor: claude-code
  id: 01kz8shp6pywvq8nykzs5m9p18
  text: |-
    ### review — clean
    - evidence: 0 new findings — review sha HEAD~1..HEAD at the time (commit a72f03e, event-based sync in HumanWaitGateTests), local backend, 9 validators attempted, 0 failed; no prior findings sections existed and all acceptance criteria were checked.
    - note: the review agent reported this result and the move to done, but its board writes did not persist; the orchestrator is recording the step and completing the review → done move on its behalf.
    - next: done
  timestamp: 2026-08-05T11:04:42.966278+00:00
position_column: done
position_ordinal: f280
title: '[Router] Flaky test: HumanWaitGateTests "a turn parked in awaitingUser frees the per-model gate, so another session over the same model still generates"'
---
Observed 2026-08-05 during full `swift test` runs while working ^ew49xjj (no code under test changed between runs — only a test rename in ToolOutputCappingTests.swift):

- Run 1: green (721/69 suites).
- Run 2: `Tests/FoundationModelsRouterTests/HumanWaitGateTests.swift` — Test "a turn parked in awaitingUser frees the per-model gate, so another session over the same model still generates" recorded an issue: `Expectation failed: await fixture.observer.exited == ["b"]` (suite "Human waits release the per-model generation gate, never the per-session turn lock").
- Run 3 (immediately after, same tree): green.

Timing-sensitive concurrency assertion — the observer's exited list presumably races the parked turn's gate release. Diagnose the race in the test (or the gate, if the race is real) and make the test deterministic — e.g. wait on the gate-released signal before asserting `observer.exited`, rather than relying on scheduling order.

## Acceptance Criteria
- [x] Root cause identified (test-side race vs product-side race) and recorded on this card
- [x] The test passes deterministically (e.g. repeated runs / `swift test --filter HumanWaitGateTests` in a loop stay green)
- [x] No product behavior change unless the race is proven product-side #router-first #flaky-test