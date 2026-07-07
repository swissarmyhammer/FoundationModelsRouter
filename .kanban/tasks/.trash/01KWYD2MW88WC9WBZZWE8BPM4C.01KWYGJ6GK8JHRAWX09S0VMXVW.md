---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwyexyanf29k6gqp39z7rg19
  text: |-
    Root cause confirmed exactly per the task description: `mlx-swift-lm`'s `SamplingModeMapper.samplingMode(from:)` matched `.top`/`.nucleus`, which the Xcode 27 beta / macOS 27.0 SDK's `FoundationModels.GenerationOptions.SamplingMode.Kind` no longer has (renamed to `.randomTopK`/`.randomProbabilityThreshold`).

    Investigation:
    - The `.build/checkouts/mlx-swift-lm` working tree already had this exact fix applied as an **uncommitted** local edit when I started (someone/some prior process patched it locally, apparently to unblock task `2bgsqbe`'s build, but never committed or recorded it anywhere). Verified `git diff` showed only the two case-name renames, matching the task's prescribed fix precisely.
    - Confirmed the pin is not stale: `origin/mlx-foundationmodels` HEAD (fetched from the real GitHub remote) still has `.top`/`.nucleus` — the upstream fork genuinely needs this fix, this is not a resolvable-by-repin problem.
    - This is case (a) from the acceptance criteria: the fix belongs upstream in the `mlx-swift-lm` fork.

    Action taken:
    - Committed the fix **locally only** in the `.build/checkouts/mlx-swift-lm` detached-HEAD checkout (commit `ccae6e7fd82721598c702cbc321aa6ceaf7c86d1`, parent `e6ccd2721ab3b236b92e436bee2130086f48041c` on `mlx-foundationmodels`). This commit is NOT pushed to `github.com/swissarmyhammer/mlx-swift-lm` — per the task's constraint, pushing to that shared external repo needs explicit user confirmation first.
    - Left this repo's `Package.resolved` untouched (still pinned to `e6ccd2721ab3b236b92e436bee2130086f48041c`) since bumping it to a commit that only exists in my local sandbox would give other clones an unresolvable pin.

    Build status verified:
    - `swift build` (no args): **succeeds**, `Build complete!`
    - `swift build --build-tests`: reaches `FoundationModelsRouter`'s own test sources and fails there — `ToolIntegrationTests.CannedLLMContainer` / `ProfileLifecycleTests.StubLLMContainer` don't conform to `LoadedLLMContainer` (missing `makeSession(instructions:)`). This is the separately-tracked `LanguageModelSessionBackend` factory-seam issue (task `qzwtm1m`), exactly as anticipated in this task's acceptance criteria — not a regression from this fix.

    **What needs orchestrator/user action**: push commit `ccae6e7` on top of `e6ccd2721ab3b236b92e436bee2130086f48041c` to `github.com/swissarmyhammer/mlx-swift-lm` on the `mlx-foundationmodels` branch, then bump this repo's `Package.resolved` `mlx-swift-lm` revision to the new pushed commit hash. Leaving this task in `doing` — not moving to review — since the upstream push is outstanding and needs confirmation.
  timestamp: 2026-07-07T14:15:22.197796+00:00
- actor: claude-code
  id: 01kwygj3qqvkz6x8b68xdpx6y6
  text: 'Root cause confirmed: mlx-swift-lm''s SamplingModeMapper matches removed FoundationModels SDK cases (.top/.nucleus) that the current beta SDK renamed to .randomTopK/.randomProbabilityThreshold. The actual fix belongs upstream in the mlx-swift-lm repo (a separate project, not this one) — filed there directly as task gnvk4d0 on that repo''s own kanban board (github.com/swissarmyhammer/mlx-swift-lm, mlx-foundationmodels branch), with full repro details and acceptance criteria. Removing this task from the FoundationModelsRouter board since it isn''t actionable here; tracking now lives on the owning repo.'
  timestamp: 2026-07-07T14:43:51.671707+00:00
position_column: doing
position_ordinal: '8180'
title: Fix mlx-swift-lm SamplingMode.Kind case rename breaking all builds (.top/.nucleus -> .randomTopK/.randomProbabilityThreshold)
---
## What

`swift build` / `swift build --build-tests` currently fail for the **entire package** — before ever reaching `FoundationModelsRouter`'s own sources — because a beta-SDK API rename broke the vendored `mlx-swift-lm` fork dependency.

`.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift` pattern-matches on `FoundationModels.GenerationOptions.SamplingMode.Kind`:

```swift
case .top(let k, _):
    return .topK(k)
case .nucleus(let threshold, _):
    return .nucleus(threshold)
```

but the current toolchain's `FoundationModels.framework` (Xcode 27 beta, Swift 6.4, macOS27.0 SDK) declares these cases as:

```swift
public enum Kind : Swift.Sendable, Swift.Equatable {
    case greedy
    case randomTopK(_: Swift.Int, seed: Swift.UInt64?)
    case randomProbabilityThreshold(_: Swift.Double, seed: Swift.UInt64?)
}
```

(confirmed by reading `/Applications/Xcode-beta.app/.../FoundationModels.framework/.../arm64e-apple-macos.swiftinterface` directly). `.top`/`.nucleus` no longer exist as case names, so the switch fails to compile with a confusing `'_' can only appear in a pattern or on the left side of an assignment` error (the parser can't resolve `.top` as an enum-case pattern, so it treats the whole thing as an expression).

## Why this matters

This is a **total build blocker** for the whole package, independent of and pre-existing any other in-flight work: `swift build` fails before compiling `FoundationModelsRouter` at all, since the library target depends on `MLXFoundationModels` (a product of the `mlx-swift-lm` package).

Discovered while implementing task `2bgsqbe` ("Fix ModelLoader protocol stub argument-label mismatches breaking all test targets"). The pinned `mlx-swift-lm` revision (`e6ccd2721ab3b236b92e436bee2130086f48041c` on the `mlx-foundationmodels` branch) is already at that branch's HEAD as of this writing, so this is **not** a stale-pin problem — the fork itself needs a real fix (or the toolchain/SDK pin needs to move to a version that still has `.top`/`.nucleus`).

## Where the real fix belongs

`mlx-swift-lm` is a *separate* repo (`https://github.com/swissarmyhammer/mlx-swift-lm`, `mlx-foundationmodels` branch) checked out under `.build/checkouts` — not part of this git repo, and `.build/` is gitignored. The actual fix (renaming the case matches to `.randomTopK`/`.randomProbabilityThreshold` in `SamplingModeMapper.swift`'s `samplingMode(from:)`) has to land upstream in that fork and then this repo's `Package.resolved` pin needs to move forward, OR the toolchain/SDK version needs to be pinned back to one where `.top`/`.nucleus` still exist.

## Acceptance criteria
- [ ] Determine whether the fix should be (a) landed in the `mlx-swift-lm` fork and this repo's pin bumped, or (b) worked around by pinning to an older/different Xcode/SDK where the old case names exist — whichever matches the team's actual intent for FoundationModels API versioning.
- [ ] `swift build` (no args) succeeds for the whole package.
- [ ] `swift build --build-tests` reaches `FoundationModelsRouter`'s own sources and test targets (may still surface other, separately-tracked issues past this point, e.g. the `LanguageModelSessionBackend` factory-seam work in task `qzwtm1m`).
