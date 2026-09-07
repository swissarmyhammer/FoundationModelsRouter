---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ycahtq8gy45vypax77786r
  text: |-
    Research and discoveries while migrating the six suites off `release()`.

    The drain point. `Router.resolve` calls `drainPendingReleases()` at the top of `runResolvePipeline`, before it measures the host budget. `ResidencyHold.deinit` also starts an unstructured drain task, but that task is not deterministic. So each migrated case is written as: drop the reference, then resolve, then read the eviction count. That keeps every count assertion with the same number and needs no `Task.sleep`, no retry loop and no added `Task.yield`.

    Three references keep a residency alive that a reader can miss:
    1. A `let` local in a test lives to the end of the function in a debug build, so a second profile must be dropped too, not only the first.
    2. A finished `Task` holds its own result. `resolveBTask` in the interleaving test was a second reference to B's profile, and the eviction count stayed at 2 instead of 5 until that handle was cleared as well.
    3. A vended `RoutedSession` retains its owning profile, so a session must stay a temporary in the statement that uses it.

    The gated ref traps a naive drain resolve. In the interleaving test `org/race-b-std` blocks in `loadLLM` until `releaseGate` is signalled, and that gate is consumed once. A final drain resolve of profile B reloads that ref and never returns — the run hung for 900 s. The final drain point is a resolve of profile A instead, which names no gated ref.

    Warning shape. A Swift local that is only ever written draws `variable was written to, but never read`, so a bare `profile = nil` is not usable where the variable has no other read. The migration adds `Tests/FoundationModelsRouterTests/Helpers/ResidencyDrop.swift`: a `mutating func dropReference()` on `Optional where Wrapped == LanguageModelProfile`. Passing the variable as the receiver of a mutating method counts as a read, so the compiler stays silent. A top-level `func` was refused because the `immutability` rule states that a function belongs to a type.

    `ToolInvocationLivenessTests` had no residency `release()` at all: `GatedMarkerTool.release()` was a test gate. It is renamed `openGate()`, with `gateSignal`/`gateContinuation` beside it, so the acceptance grep is clean and the name no longer collides with residency release.
  timestamp: 2026-09-07T16:48:18.775599+00:00
- actor: claude-code
  id: 01m1ycarj22b7j2babp19zqwve
  text: |-
    ### implement — changed
    - evidence: 7 files — Tests/FoundationModelsRouterTests/PooledResidencyTests.swift, ProfileLifecycleTests.swift, ToolSharedProfileTests.swift, ExamplesTests.swift, ToolInvocationLivenessTests.swift, TranscriptTreeAccessTests.swift, and the new Helpers/ResidencyDrop.swift. `swift build --build-tests` after `touch` on every test file: zero warnings, zero errors. `swift test`: 1234 tests in 134 suites passed, plus 83 tests in 10 suites in the evals target, exit 0, 2 pre-existing known issues. `swift test --filter PooledResidencyTests`: 15 tests passed. `grep -rn '\.release()' Tests/` returns nothing.
    - next: /review
  timestamp: 2026-09-07T16:48:25.666433+00:00
- actor: claude-code
  id: 01m1ycggeyyxqw3w9jp0c505ts
  text: |-
    ### test — green
    - evidence: `swift package clean` then `swift build --build-tests` — 0 errors, 5 warnings, all 5 from the vendored `mlx-swift` checkout (C++17-extension notices in its Metal headers, plus one bundle-creator notice), none from `Sources/` or `Tests/`. `swift test` — two binaries: 1234 tests in 134 suites passed (2 known issues, both by design, in `RealModelHarness.swift` and `BoundedWait.swift`), and 83 tests in 10 suites passed. 0 failed, 0 skipped.
    - invariant 1: `grep -rn '\.release()' Tests/` returns nothing.
    - invariant 2: the diff adds no `Task.sleep`, no retry loop, and no new `Task.yield`.
    - the "Pooled model residency" suite (PooledResidencyTests.swift) passed all cases, including the gated-ref case ("a live session retains its profile...", 0.451s) and the interleaving case ("a dropped residency cannot interleave with an in-flight resolve...", 2.330s) — no hang observed.
    - next: hand to review.
  timestamp: 2026-09-07T16:51:33.982596+00:00
depends_on:
- 01M1Y6ESW0C8F9M0AKFFA7B61C
position_column: doing
position_ordinal: '80'
title: Prove eviction by dropping references instead of calling release() in the router suites
---
## What

After `^fa7b61c` lands, a pooled model is evicted when the last reference to it goes away, and `Router.resolve` drains the pending evictions before it measures the budget. `LanguageModelProfile.release()` still exists at that point, and six suites still drive eviction through it. This task moves those suites onto the reference-drop path, so nothing but the examples and the docs still calls `release()`.

Rewrite each `release()` call in the suites below into: drop the profile and every handle built from it, then observe the eviction at the next `resolve` (the drain point). Keep every existing assertion about load counts, eviction counts and typed failures — only the trigger changes.

Files, all under this repo:

- `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` — the largest user (`:426`, `:431`, `:597`, `:692`, `:770`). The suite's `LoadSpy` (`:112`) already counts evictions, so the assertions carry over unchanged.
- `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift`
- `Tests/FoundationModelsRouterTests/ToolSharedProfileTests.swift`
- `Tests/FoundationModelsRouterTests/ExamplesTests.swift` — this suite is the worked-example documentation, so its residency example must read as the shape a caller should copy: resolve, use, drop.
- `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift`
- `Tests/FoundationModelsRouterTests/TranscriptTreeAccessTests.swift`

Note for the implementer: a handle that outlives its profile object cannot call `makeSession` — it needs the sibling slots and traps at `Sources/FoundationModelsRouter/RoutedLLM.swift:30`. Where a test must act on a model after the profile is gone, use `RoutedEmbedder.embed(texts:)` (`Sources/FoundationModelsRouter/RoutedEmbedder.swift:44`), which needs no profile.

The interleaving test at `PooledResidencyTests.swift:627` ("a release cannot interleave with an in-flight resolve") is about pool-lock ordering, not about the public API. Keep the case and drive it through the same lock path the drain uses.

- [ ] Migrate `PooledResidencyTests.swift` off `release()`.
- [ ] Migrate `ProfileLifecycleTests.swift`, `ToolSharedProfileTests.swift` and `ExamplesTests.swift`.
- [ ] Migrate `ToolInvocationLivenessTests.swift` and `TranscriptTreeAccessTests.swift`.
- [ ] Preserve the interleaving case at `PooledResidencyTests.swift:627` against the drain path.

## Acceptance Criteria

- [ ] `grep -rn '\.release()' Tests/` returns nothing.
- [ ] No suite gained a `Task.sleep`, a retry loop or a `Task.yield` to see an eviction.
- [ ] Every eviction-count assertion that exists today still exists, with the same expected number.
- [ ] The `ExamplesTests` residency example shows resolve → use → drop, and calls no cleanup method.
- [ ] `swift build` reports no new warnings.

## Tests

- [ ] Run `swift test`. Every suite passes.
- [ ] Confirm the migrated tests actually executed — check the reported test count, because a `--filter` that matches a display name instead of a type name matches nothing and still exits `0`.
- [ ] `Tests/FoundationModelsRouterTests/PooledResidencyTests.swift` keeps proving all three cases it proves today: dedup (one load for two profiles), no eviction while a second reference lives, and eviction of all three models once nothing references them.

## Workflow

- Use `/tdd` — change one suite at a time and keep the rest green.
#router #tests #tech-debt