---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwky2w83wpf7v74g3v99ah3j
  text: |-
    Added three unit tests for DownloadProgress.fraction in Tests/FoundationModelsRouterTests/ResolveTests.swift, under the existing "MARK: - Progress fraction math" section (alongside SlotProgress.progressFraction tests):
    - downloadProgressFractionDividesKnownTotal: 5/10 -> 0.5
    - downloadProgressFractionZeroWhenTotalUnknown: bytesTotal 0 -> fraction 0, not NaN
    - downloadProgressFractionCompleteIsOne: 100/100 -> exactly 1.0

    No production code changed (fraction was already correct, just uncovered). Full suite: swift test -> 132/132 tests pass (plus 1 gated integration test skipped as expected), 0 failures. Adversarial double-check agent returned PASS with no findings. Leaving task in doing for review.
  timestamp: 2026-07-03T12:08:33.795981+00:00
position_column: doing
position_ordinal: '80'
title: Add tests for DownloadProgress.fraction
---
Sources/FoundationModelsRouter/Resolution/ModelLoader.swift:27-29

Coverage: 0% (0/3 lines)

Uncovered lines: 27-29

```swift
public var fraction: Double {
    bytesTotal > 0 ? Double(bytesDownloaded) / Double(bytesTotal) : 0
}
```

`DownloadProgress` is constructed dozens of times across the test suite (`DownloadProgress(bytesDownloaded:bytesTotal:)`), but the `fraction` computed property itself is never read by any test — grep confirms no `.fraction` access in Tests/, and the only production use is `Router.swift:699` setting `progress.fraction = 1.0` on `ResolutionProgress` (a different type). This is pure, dependency-free arithmetic — no MLX, no network.

Write direct unit tests (e.g. in ResolveTests.swift or a new small suite) covering:
- `bytesTotal > 0`: fraction is `bytesDownloaded / bytesTotal` (e.g. 5/10 → 0.5).
- `bytesTotal == 0`: fraction is `0` (not divide-by-zero/NaN) — the documented "total unknown" case.
- `bytesDownloaded == bytesTotal`: fraction is exactly `1.0`.