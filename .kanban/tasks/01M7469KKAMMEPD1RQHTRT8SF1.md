---
assignees:
- claude-code
depends_on:
- 01M7468WP7Q3TQZ31MBTKJJW9J
position_column: todo
position_ordinal: '8380'
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
- [ ] A tree listing with `decider_config.json` sets the flag; a listing without it does not.
- [ ] `DecisionFormatLoader.format` gives a `DeciderPromptFormat` whose configuration equals the fixture config, and fetches at the revision of the reference.
- [ ] With no config file, it gives `GenericPromptFormat` and makes no fetch.
- [ ] A local model directory with the file gives the decider format.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/DecisionFormatLoaderTests.swift` with a stub `MetadataSource` that records each fetch (path and revision): config present, config absent (no fetch), revision passes through, malformed config throws, local directory in a test temp directory (clean it up; see the memory note on test temp dirs).
- [ ] Add a case to the existing `RepoMetadata` parsing tests for the flag.
- [ ] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision