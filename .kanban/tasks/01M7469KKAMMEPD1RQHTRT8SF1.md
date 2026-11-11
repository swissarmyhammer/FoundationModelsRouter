---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m75ddpwvbk4z8h6febwgv4gy
  text: |-
    Research and design (implement step):
    - `RepoMetadata` now has `let deciderConfigurationByteCount: Int64?` and the computed `hasDeciderConfiguration`. The size (not only a flag) comes from the tree listing (`TreeEntry.byteCount`, so the LFS size when present). `DecisionFormatLoader` uses it as the exact range of the whole-file read with `fetchFileBytes`. A negative size is clamped to an empty range, and the decode then fails.
    - `RepoMetadata.recordingDeciderConfiguration(in:)` gives a copy through the core init, so the property stays `let`. Three callers apply it: `init(raw:repo:)`, `RepoMetadataReader.parseAndCache` (both the GGUF and the MLX branch), and `init(localLocation:)` for a local folder (GGUF and MLX). A local single `.gguf` file has no folder, so it has no value.
    - Only a file at the repository root counts. `extra/decider_config.json` does not.
    - The value is in the Codable cache entry. An old cache entry decodes with `nil` (optional field); a commit-pinned entry written before this change therefore shows no config until it is refreshed. ARCHITECTURE.md says no backward compatibility, so no migration.
    - Errors are not wrapped: a source error or a `DecodingError` goes to the caller (R2/R6), which logs it and uses the flash fallback.
    - Changed the two error messages of `fetchFileBytes` (live HTTP status and the default refusal) so that they no longer say "GGUF header": the read now also serves the config file. No test asserted those texts.
    - `PooledDecisionContainer` and its `ReasoningOffPromptFormat` wrap are not changed.
  timestamp: 2026-11-11T13:40:40.987986+00:00
- actor: claude-code
  id: 01m75ddtn32etbd1f4m5qbajeq
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Resolution/DecisionFormatLoader.swift (new), Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift, Sources/FoundationModelsRouter/Sizing/LocalRepoMetadata.swift, Tests/FoundationModelsRouterTests/DecisionFormatLoaderTests.swift (new, 7 tests), Tests/FoundationModelsRouterTests/RepoMetadataTests.swift (+3), Tests/FoundationModelsRouterTests/GGUFRepoMetadataTests.swift (+1), Tests/FoundationModelsRouterTests/LocalRepoMetadataTests.swift (+3). RED: `swift build --build-tests` failed with "cannot find 'DecisionFormatLoader' in scope". GREEN: filtered run, 14 tests in 4 suites passed. Full `swift test` one time: exit 0; 2566 tests in 299 suites, 38 in 23, 19 in 3, all passed; no compiler warnings.
    - next: /review
  timestamp: 2026-11-11T13:40:44.835915+00:00
depends_on:
- 01M7468WP7Q3TQZ31MBTKJJW9J
position_column: doing
position_ordinal: '80'
title: 'R7a: fetch decider_config.json through the metadata source and select the prompt format'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R5 and R7, decision D13. The pool downloads only the GGUF file of a decider reference. The prompt format needs the `decider_config.json` of the same repository at the same revision.

Design (decided): do not add a method to the `ModelLoader` protocol. The resolve already reads the tree listing of each candidate through `MetadataSource` (`Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift`). Use that source for the config file too, so that unit tests use the existing stub sources (`Tests/FoundationModelsRouterTests/Helpers/FileServingMetadataSource.swift`) and download no file.

- `Sizing/RepoMetadata.swift`: when the tree listing has a file `decider_config.json` at the repository root, record it on `RepoMetadata` (for example `let hasDeciderConfiguration: Bool`).
- `Sizing/LocalRepoMetadata.swift`: the same for a local model directory (`Core/LocalModelPath.swift`).
- New `Sources/FoundationModelsRouter/Resolution/DecisionFormatLoader.swift`: `static func format(for ref: ModelRef, metadata: RepoMetadata, source: any MetadataSource) async throws -> any DecisionPromptFormat`. With the flag: fetch the whole file with `MetadataSource.fetchFileBytes(repo:revision:path:range:)` at the revision of `ref` (or read the local file), then call `DecisionFormatSelection.format(deciderConfiguration:)` (R5). With no flag: `GenericPromptFormat()` with no fetch.
- Errors: a fetch error or a malformed config is a resolve error of the decision slot only. The caller (R2/R6 task) logs it and uses the flash fallback; it never blocks the profile.

## Acceptance Criteria
- [x] A tree listing with `decider_config.json` sets the flag; a listing without it does not.
- [x] `DecisionFormatLoader.format` gives a `DeciderPromptFormat` whose configuration equals the fixture config, and fetches at the revision of the reference.
- [x] With no config file, it gives `GenericPromptFormat` and makes no fetch.
- [x] A local model directory with the file gives the decider format.

## Tests
- [x] New `Tests/FoundationModelsRouterTests/DecisionFormatLoaderTests.swift` with a stub `MetadataSource` that records each fetch (path and revision): config present, config absent (no fetch), revision passes through, malformed config throws, local directory in a test temp directory (clean it up; see the memory note on test temp dirs).
- [x] Add a case to the existing `RepoMetadata` parsing tests for the flag.
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision