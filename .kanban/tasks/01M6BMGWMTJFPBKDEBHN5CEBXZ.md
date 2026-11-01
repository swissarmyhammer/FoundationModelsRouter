---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bnd4skmy689vkg8qkhm1kn
  text: |-
    ### review — findings
    - evidence: review sha 9def1244~1..9def1244 — 2 findings (confirmed 2): Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:124, Tests/FoundationModelsRouterTests/RepoMetadataTests.swift:897
    - next: fix both findings, then run review again. Task stays in review.
  timestamp: 2026-11-01T13:39:55.827375+00:00
- actor: claude-code
  id: 01m6bnkzshjq33rmhksnmsrk60
  text: |-
    ### review — findings
    - evidence: review sha 0091d6e8~1..0091d6e8, 1 finding: Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:192 (duplication of decode-and-wrap in decodeTreeEntries and sizingSource). Both earlier findings are checked.
    - next: implementer extracts one generic decode helper and uses it in both places, then review again.
  timestamp: 2026-11-01T13:43:40.081118+00:00
- actor: claude-code
  id: 01m6bnv29r7pbfdsh25aqpabsc
  text: |-
    ### review — clean
    - evidence: review sha 66ac7010~1..66ac7010 — 0 findings (0 confirmed, 0 refuted, 7 attempted, 0 failed). All prior items are checked.
    - next: task moved to done.
  timestamp: 2026-11-01T13:47:32.024185+00:00
position_column: done
position_ordinal: ffffffffd280
title: Size a CoreML embedding repo in the router
---
Check that RepoMetadata and Footprint.embedder(weightBytes:) size a CoreML repo (.mlpackage or .mlmodelc files) correctly. Fix them if they do not. Decide how joint fit counts an ANE model against the memory budget. Add unit tests with stub repo metadata. Context: the default embedding model will be erjigit17/embeddinggemma-300m-ane-coreml. This task does not depend on the Extras API.

## Review Findings (2026-11-01 07:37)

> Scope: `review sha 9def1244~1..9def1244` — reviewed the diffs only — lines this change added or modified. 5 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:124` `swift/error-handling` — The tree listing is decoded with `try?` and a `?? []` fallback. A malformed listing is turned into an empty list without an error. The caller cannot learn that the listing was bad. The later guard then reports the wrong cause, "no *.safetensors weight files or Core ML bundles", for what is really a decode failure. Decode with `try` so that a bad listing throws. Map the error to `RepoMetadataError.metadataUnavailable` with a message that names the decode failure, for example `let entries = try decodeTreeEntries(raw.treeJSON, repo: repo)`. The weight-file error then means only that the listing decoded and held no weights.
- [x] `Tests/FoundationModelsRouterTests/RepoMetadataTests.swift:897` `test-integrity/no-test-cheating` — The test repoWithNoWeightsIsAnError asserts only that some RepoMetadataError is thrown. For this input (configJSON: nil, no weight files), the config.json guard in RepoMetadata.init(raw:repo:) runs before the new no-weights guard, so the test passes because config.json is missing, not because the tree has no weights. The test does not prove the behaviour its name claims, so it can pass when the new check is broken. Pass a valid config.json (for example Self.fullConfigJSON) so the config guard passes, and assert the specific message, such as `metadataUnavailable("no *.safetensors weight files or Core ML bundles in the repo tree")`. Then the test fails if the weight check is removed.

## Review Findings (2026-11-01 07:42)

> Scope: `review sha 0091d6e8~1..0091d6e8` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 0 not reviewed.

- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:192` `duplication/duplication` — The new `decodeTreeEntries` repeats the decode-and-wrap logic of `sizingSource`. Both use `JSONDecoder().decode(...)` inside a `do`/`catch` that rethrows `RepoMetadataError.metadataUnavailable`. Only the decoded type and the message text differ. If one copy changes, the other can drift, for example in how it reports decode errors. Extract one generic helper, for example `private static func decode<T: Decodable>(_ type: T.Type, from data: Data, what: String) throws -> T`, that wraps the `do`/`catch` and builds the message from `what`. Call it from both `decodeTreeEntries` and `sizingSource`, and delete the two copies of the wrapper.
