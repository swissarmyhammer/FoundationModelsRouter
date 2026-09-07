---
assignees:
- claude-code
depends_on:
- 01M1Y6ESW0C8F9M0AKFFA7B61C
position_column: todo
position_ordinal: '8180'
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