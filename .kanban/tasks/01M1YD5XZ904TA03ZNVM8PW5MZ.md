---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Correct the stale deinit description in OwningProfileTests
---
## What

`Tests/FoundationModelsRouterTests/OwningProfileTests.swift` has a suite doc comment that describes a `LanguageModelProfile.deinit`. That deinit does not exist. Card `^fa7b61c` made residency ARC-owned through `ResidencyHold`, and the class doc of `LanguageModelProfile` now says the opposite: "This object needs no hold of its own, and no `deinit`".

Two sentences are wrong:

- "A strong back-reference would make a cycle, and `LanguageModelProfile.deinit`, which gives the residency back to the router, would never run."
- "The release test is deterministic for the same reason: `deinit` clears the weak slot as the profile is deallocated, and the `Task` that `deinit` starts captures the router and the token only, never the profile, so no assertion here depends on when that task runs."

The deinit that does this work is `ResidencyHold.deinit`, which calls `Router.enqueuePendingRelease(_:)`. The weak slot clears because ARC deallocates the profile, not because a deinit body clears it.

- [ ] Correct both sentences to name `ResidencyHold.deinit` and the ARC deallocation.

## Acceptance Criteria

- [ ] No comment in the file names a `LanguageModelProfile.deinit`.
- [ ] `swift test` stays green.

## Notes

Found while doing `^m8vj0jr`. That card deleted `LanguageModelProfile.release()`, and left this doc alone because the staleness came in with `^fa7b61c` and correcting it is not on that card.

#router #cleanup #docs