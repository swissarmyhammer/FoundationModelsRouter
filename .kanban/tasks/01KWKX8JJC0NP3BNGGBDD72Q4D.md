---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwm9geg3xpbv7167atbc4w95
  text: |-
    Implemented: added 4 new tests to Tests/FoundationModelsRouterTests/ResolveTests.swift covering Router's private sizeCandidates/footprintBytes/preferLarger (exercised only indirectly via the public resolve(_:reporting:) since they're private):

    1. mergeKeepsLargerSuccessfulFootprintAcrossSlots — preferLarger's (.success,.success) branch: a ModelRef shared as sole candidate for both embedding and standard slots sizes differently per slot (embedder formula vs weights+KV formula on the same metadata); a budget set strictly between the two margined footprints (12,000,000 vs 14,516,583) proves the merge kept the larger, via the thrown ResolutionFailure's CandidateReport.estimatedFootprintBytes.
    2. mergePrefersSuccessOverAnEarlierFailure — (.failure,.success) branch: a ref shared by standard+flash whose fetch fails once then succeeds (call-count scripted, order-independent since sizeCandidates iterates sequentially); resolve() succeeds and both slots choose it.
    3. mergeKeepsFirstFailureAcrossSlots — (.failure,.failure) branch: same shared-ref pattern, both fetches fail with different messages; asserts the merged verdict keeps the chronologically-first message (order-independent by construction).
    4. footprintBytesPassesRepoMetadataErrorThroughAndWrapsGenericError — footprintBytes' two catch branches: a candidate whose fetch throws RepoMetadataError directly (passed through unchanged) vs one throwing a generic URLError (wrapped into .metadataUnavailable(localizedDescription)).

    Added a new ScriptedMetadataSource actor stub (alongside the existing StubMetadataSource) that scripts per-repo fetch outcomes consumed one per call, falling back to a default raw fixture for unscripted repos — needed because the existing stub can't simulate throwing/sequenced behavior.

    Note: preferLarger's fourth switch arm, (.success, .failure), is structurally unreachable via the router's real call path — RepoMetadataReader's on-disk cache commits after any successful fetch, so a later fetch for the same ref can never regress from success back to failure within one resolve() call. Verified this by reading RepoMetadataReader.metadata(for:)'s cache.load → source.fetch → parse → cache.save structure; confirmed independently by the double-check agent. Only 3 of the 4 switch arms are reachable through resolve(), and all 3 are now covered.

    Verification: manually mutated Router.swift's preferLarger (max→min, swapped the two failure-branch returns) and confirmed all 3 merge tests fail against the mutation, then reverted (git diff on Router.swift is clean — zero production code changed, test-only task). swift test: 152/152 tests pass in the main target (1 gated integration test skipped as expected), zero failures/warnings. double-check agent (adversarial review): PASS, no findings.

    Leaving task in doing per the implement skill — ready for /review.
  timestamp: 2026-07-03T15:28:12.803957+00:00
position_column: done
position_ordinal: '9e80'
title: Add tests for Router candidate-sizing merge and failure paths
---
Sources/FoundationModelsRouter/Router.swift — `sizeCandidates`/`footprintBytes`/`preferLarger` (lines 389, 415-418, 426-437)

Coverage: 94.6% (351/371 lines) overall; these specific branches in the pre-joint-fit sizing step are 0% covered.

Uncovered lines and what they need:

1. **`preferLarger` merge logic (426-437) + its call site (389)** — hit only when the *same* `ModelRef` appears as a candidate for more than one slot in a `ProfileDefinition` (e.g. reusing one model ref for both `standard` and `flash`, or across a generation slot and `embedding`). No existing `ResolveTests.swift` profile does this, so `sizeCandidates`'s dedup path, and all four `preferLarger` branches — `(.success,.success)` (keeps `max`), `(.success,.failure)`, `(.failure,.success)`, `(.failure,.failure)` — are untested. Add a resolve test with a `ProfileDefinition` where one `ModelRef` is listed as a candidate under two slots, driving a stub `MetadataSource`/`MachineProbe` combination to produce each of the four success/failure permutations, and assert the merged result matches `preferLarger`'s documented "keep the larger success, prefer success over failure" rule.

2. **`footprintBytes` catch branches (415-418)** — every existing resolve test's `MetadataSource` stub only succeeds, so sizing failure is never exercised. Add a test where the stub `MetadataSource.fetchRawMetadata` throws (a) a `RepoMetadataError` directly, and (b) a generic `Error`, and assert `footprintBytes` (exercised via `resolve`) wraps case (b) into `.metadataUnavailable(error.localizedDescription)` while passing case (a) through unchanged — and that the candidate is correctly treated as unavailable during joint-fit.