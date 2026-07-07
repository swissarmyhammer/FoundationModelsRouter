---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
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
