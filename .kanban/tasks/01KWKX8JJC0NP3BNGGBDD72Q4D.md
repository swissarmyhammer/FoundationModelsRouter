---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: Add tests for Router candidate-sizing merge and failure paths
---
Sources/FoundationModelsRouter/Router.swift — `sizeCandidates`/`footprintBytes`/`preferLarger` (lines 389, 415-418, 426-437)

Coverage: 94.6% (351/371 lines) overall; these specific branches in the pre-joint-fit sizing step are 0% covered.

Uncovered lines and what they need:

1. **`preferLarger` merge logic (426-437) + its call site (389)** — hit only when the *same* `ModelRef` appears as a candidate for more than one slot in a `ProfileDefinition` (e.g. reusing one model ref for both `standard` and `flash`, or across a generation slot and `embedding`). No existing `ResolveTests.swift` profile does this, so `sizeCandidates`'s dedup path, and all four `preferLarger` branches — `(.success,.success)` (keeps `max`), `(.success,.failure)`, `(.failure,.success)`, `(.failure,.failure)` — are untested. Add a resolve test with a `ProfileDefinition` where one `ModelRef` is listed as a candidate under two slots, driving a stub `MetadataSource`/`MachineProbe` combination to produce each of the four success/failure permutations, and assert the merged result matches `preferLarger`'s documented "keep the larger success, prefer success over failure" rule.

2. **`footprintBytes` catch branches (415-418)** — every existing resolve test's `MetadataSource` stub only succeeds, so sizing failure is never exercised. Add a test where the stub `MetadataSource.fetchRawMetadata` throws (a) a `RepoMetadataError` directly, and (b) a generic `Error`, and assert `footprintBytes` (exercised via `resolve`) wraps case (b) into `.metadataUnavailable(error.localizedDescription)` while passing case (a) through unchanged — and that the candidate is correctly treated as unavailable during joint-fit.