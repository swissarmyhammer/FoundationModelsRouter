---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwm08eq29f1zkfg1wwjnrrth
  text: |-
    Implemented. Added three @Test functions to Tests/FoundationModelsRouterTests/RepoMetadataTests.swift, each constructing a RawRepoMetadata directly and calling RepoMetadata(raw:) (no reader/cache, no I/O) with exact-string #expect(throws: RepoMetadataError.metadataUnavailable("...")) assertions:
    - malformedConfigJSONUnavailable — non-JSON configJSON bytes -> "config.json could not be parsed" (line ~127)
    - missingArchitectureFieldsUnavailable — valid JSON missing num_hidden_layers/num_attention_heads -> "config.json is missing num_hidden_layers or num_attention_heads" (lines ~133-135)
    - missingHeadSizingFieldsUnavailable — valid JSON with layers/heads but neither head_dim nor hidden_size -> "config.json has neither head_dim nor hidden_size to size a head" (lines ~138-140)

    No production code changes. Sanity-checked the tests are not vacuous: temporarily broke the parse-failure error message in RepoMetadata.swift, confirmed the corresponding test failed with a clear diff, then reverted (git diff on Sources/ now empty).

    Verification: `swift test --filter RepoMetadataTests` -> 12/12 pass. Full `swift test` -> 139/139 pass (1 gated integration test skipped, unrelated). double-check agent adversarial review returned PASS, no findings.

    Leaving task in doing per /implement contract; ready for /review.
  timestamp: 2026-07-03T12:46:33.698731+00:00
position_column: done
position_ordinal: 9c80
title: Add tests for RepoMetadata.init(raw:) error branches
---
Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:122-151 (error branches: 127, 133-135, 138-140)

Coverage: 79.5% (93/117 lines) in RepoMetadata.swift overall; these specific throw branches are 0% covered.

Uncovered lines:
- 127: `config.json could not be parsed` (JSONDecoder fails)
- 133-135: `config.json is missing num_hidden_layers or num_attention_heads`
- 138-140: `config.json has neither head_dim nor hidden_size to size a head`

The doc comment on `init(raw:)` explicitly promises: "Surfaces `RepoMetadataError.metadataUnavailable(_:)` — never crashes — when `config.json` is absent or unparseable, when it lacks the required `num_hidden_layers`/`num_attention_heads`, when it has neither `head_dim` nor `hidden_size`..." — and the type's own doc block says parsing is "testable from canned fixtures with no I/O." Only the `configJSON == nil` branch (line ~124) and the happy path are currently tested (see RepoMetadataTests.swift); the three branches above are not.

Add cases to RepoMetadataTests.swift constructing `RawRepoMetadata` with:
1. `configJSON` set to malformed/non-JSON bytes → expect `.metadataUnavailable` mentioning "could not be parsed".
2. Valid JSON missing `num_hidden_layers` or `num_attention_heads` → expect `.metadataUnavailable` mentioning the missing fields.
3. Valid JSON with layers/heads present but neither `head_dim` nor `hidden_size` → expect `.metadataUnavailable` mentioning "head_dim or hidden_size".

All three are pure, no I/O — canned `Data` fixtures only.