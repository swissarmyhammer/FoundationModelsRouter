---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1ydsb8rwk34pjcgdfdxzvr6
  text: |-
    Research done. What the code does now:

    - `ResidencyHold` (Sources/FoundationModelsRouter/ResidencyHold.swift) is the reference-counted claim. Its `deinit` calls `Router.enqueuePendingRelease(_:)`.
    - `Router.enqueuePendingRelease(_:)` appends the token under a lock and starts a `Task` that drains the queue. That `Task` captures the router and the token only.
    - `LanguageModelProfile` has no `deinit` and no hold of its own. Its class doc says: "This object needs no hold of its own, and no `deinit`".
    - The weak `owningProfile` slot clears because ARC deallocates the profile, not because a `deinit` body clears it.
    - `HandBuiltProfileFixtures.makeProfile` passes no `residencyHold`, so a hand-built profile in this suite carries no `ResidencyHold` at all and queues no release. That makes the release test deterministic more strongly than the current doc says.

    So the two sentences the card names are both wrong, and the phrase "once the profile is released" also reads as the deleted `LanguageModelProfile.release()`.
  timestamp: 2026-09-07T17:13:52.152421+00:00
- actor: claude-code
  id: 01m1ye480yj4rn25swehyjb75s
  text: |-
    Corrected the suite doc of Tests/FoundationModelsRouterTests/OwningProfileTests.swift.

    - The cycle sentence now says that a strong back-reference would keep the profile AND its handles alive, so the shared ``ResidencyHold`` would never drop its last reference and `ResidencyHold.deinit`, which gives the residency back to the router, would never run. It adds that the profile itself has no `deinit`, and it says the handle reports `nil` again once ARC deallocates the profile.
    - The determinism sentence now says the weak slot clears as ARC deallocates the profile, that no residency work follows, that a hand-built profile resolves nothing and therefore carries no ``ResidencyHold``, and that a real hold refers to the router and the token only.

    No comment in the file names a `LanguageModelProfile.deinit` any more. The remaining word "released" is in the `@Test` display name and the test function name, which state ARC release and name no removed API, so they stay as they are.

    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/OwningProfileTests.swift. `swift build --build-tests` recompiled the test product (12/12 tasks), no compiler warning. `swift test`: main bundle 1234 tests in 134 suites passed with 2 known issues; Evals bundle 83 tests in 10 suites passed.
    - next: /review
  timestamp: 2026-09-07T17:19:49.278119+00:00
- actor: claude-code
  id: 01m1yea2kce407pz0y62hmhbft
  text: |
    ### test — green
    - evidence: `swift package clean` then `swift build --build-tests` (exit 0, forced full recompile, 71.90s) — no warnings in our own Sources/Tests (4 warnings present are third-party, from `.build/checkouts/mlx-swift`); `swift test` (exit 0) — main bundle "Test run with 1234 tests in 134 suites passed after 5.068 seconds with 2 known issues" (both known-issue records are intentional test assertions of `withKnownIssue` matcher behavior in `RealModelHarness.swift` and `BoundedWait.swift`, not real failures), Evals bundle "Test run with 83 tests in 10 suites passed after 0.175 seconds"
    - ToolInvocationLivenessTests: suite "Tool invocation liveness: records from the binding layers, delivered mid-turn" passed on the first parallel run, no flake observed, no isolation rerun needed
    - IntegrationTests package was not run, per instruction
    - next: none
  timestamp: 2026-09-07T17:23:00.332134+00:00
- actor: claude-code
  id: 01m1yec1zs82ghb7hs4gwfwdqr
  text: |-
    ### commit — changed
    - evidence: 765460a docs(tests): correct stale deinit description in OwningProfileTests
    - next: review
  timestamp: 2026-09-07T17:24:05.241629+00:00
position_column: doing
position_ordinal: '80'
title: Correct the stale deinit description in OwningProfileTests
---
## What

`Tests/FoundationModelsRouterTests/OwningProfileTests.swift` has a suite doc comment that describes a `LanguageModelProfile.deinit`. That deinit does not exist. Card `^fa7b61c` made residency ARC-owned through `ResidencyHold`, and the class doc of `LanguageModelProfile` now says the opposite: "This object needs no hold of its own, and no `deinit`".

Two sentences are wrong:

- "A strong back-reference would make a cycle, and `LanguageModelProfile.deinit`, which gives the residency back to the router, would never run."
- "The release test is deterministic for the same reason: `deinit` clears the weak slot as the profile is deallocated, and the `Task` that `deinit` starts captures the router and the token only, never the profile, so no assertion here depends on when that task runs."

The deinit that does this work is `ResidencyHold.deinit`, which calls `Router.enqueuePendingRelease(_:)`. The weak slot clears because ARC deallocates the profile, not because a deinit body clears it.

- [x] Correct both sentences to name `ResidencyHold.deinit` and the ARC deallocation.

## Acceptance Criteria

- [x] No comment in the file names a `LanguageModelProfile.deinit`.
- [x] `swift test` stays green.

## Notes

Found while doing `^m8vj0jr`. That card deleted `LanguageModelProfile.release()`, and left this doc alone because the staleness came in with `^fa7b61c` and correcting it is not on that card.

#router #cleanup #docs