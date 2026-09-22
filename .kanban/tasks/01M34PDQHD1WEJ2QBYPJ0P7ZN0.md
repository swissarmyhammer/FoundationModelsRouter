---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34r6j9r8yqnf1yffk6n79f3
  text: |-
    ### research
    - The three constants, the diagnostic field and the clamp function are all in `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift` (lines 66-110, 141-143, 157-183).
    - The only memberwise `init` callers are `init(raw:)` in the same file and two Codable round-trip tests in `RepoMetadataTests.swift` (612, 631). No source caller uses the default.
    - No caller prints `nativeMaxContextDiagnostic`. `Router.swift` maps `RepoMetadata.nativeMaxContext` only (line 704-708).
    - `JointFit.contextLadder` (line 383-386) is the one place that reads `nativeMaxContextCap`.
    - `RepoMetadata.init(raw:)` does not know the repo. The reader (`parseAndCache`) has the `ModelRef`. Plan: add a `repo` parameter to the parse so the new error can name the repo.
    - Test fixtures: `RepoMetadataTests.fullConfigJSON` has no context field. Many reader and cache tests use it. It must get a `max_position_embeddings` field, or those tests fail with the new error. Other fixtures will be checked the same way.
    - `JointFitTests.swift:360` has a test title that says "capped" but the test does not assert a cap. The title will lose the word.
  timestamp: 2026-09-22T14:26:59.512458+00:00
- actor: claude-code
  id: 01m34rk9tkt2r9gv404rhb4rnt
  text: |-
    ### implementation landed (build and tests not yet run)
    - `RepoMetadata.swift`: the three constants, the diagnostic field and the clamp are gone. `init(raw:repo:)` reads the first context field as-is and throws `metadataUnavailable` that names the repo and the four field names when no field is present or the value is not positive. `nativeMaxContext` is a required `init` parameter. The field names in the message come from `SizingFields.nativeMaxContextKeys`.
    - `JointFit.contextLadder` uses `nativeMaxContext` as the top rung with no cap.
    - `RepoMetadataTests`: the missing-field test and the non-positive test replace the default and clamp tests. The two boundary tests now assert 10_485_760 and 2048 pass through unchanged. The second Codable test is folded into the first, because there is no default to compare against.
    - 40 test fixtures got `"max_position_embeddings": 8192`. That figure is what these fixtures got by default before this change, so the arithmetic of the tests that use them does not move. Three subagents did the mechanical part for 37 files.
    - Doc comments in `TranscriptNestingTests` and the test title in `JointFitTests:360` no longer name a default or a cap.
  timestamp: 2026-09-22T14:33:56.819799+00:00
- actor: claude-code
  id: 01m34rpg6nhwfhsga2p6afvc29
  text: |-
    ### implement — changed
    - evidence: 44 files — Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift, Sources/FoundationModelsRouter/Resolution/JointFit.swift, Tests/FoundationModelsRouterTests/RepoMetadataTests.swift, Tests/FoundationModelsRouterTests/JointFitTests.swift, Tests/FoundationModelsRouterTests/TranscriptNestingTests.swift, Tests/FoundationModelsRouterTests/ResolveTests.swift, and 38 test files whose config.json fixture gained max_position_embeddings
    - next: test
  timestamp: 2026-09-22T14:35:41.653405+00:00
- actor: claude-code
  id: 01m34rpjee3n6b0vhvrz0jns12
  text: |-
    ### test — green
    - evidence: swift test — 1353 + 1 + 83 = 1437 tests passed, 0 failed, 0 skipped (2 pre-existing withKnownIssue expectations in RealModelHarness and BoundedWait); swift build --package-path IntegrationTests --build-tests — Build complete; rg 'nativeMaxContextFloor|nativeMaxContextCap|defaultNativeMaxContext|nativeMaxContextDiagnostic' over *.swift — no matches
    - next: commit
  timestamp: 2026-09-22T14:35:43.950493+00:00
position_column: doing
position_ordinal: '80'
title: Remove the native max context floor, cap and default; use config.json as-is
---
## Decision (from the owner, 2026-09-22)

A model's window is what its `config.json` says. Router must not change that number. The three constants `nativeMaxContextFloor` (4,096), `nativeMaxContextCap` (1,048,576) and `defaultNativeMaxContext` (8,192) in `Sizing/RepoMetadata.swift:78-84` are invented limits and must go.

## Where they are used

- `RepoMetadata.swift:161-181`: the one function that reads the context field. A missing field gives 8,192. A value over the cap is lowered. A value under the floor is raised. Each case writes `nativeMaxContextDiagnostic`.
- `RepoMetadata.swift:98`: the `init` default parameter `nativeMaxContext: Int = RepoMetadata.defaultNativeMaxContext`.
- `Resolution/JointFit.swift:384`: `contextLadder` caps the top rung at `nativeMaxContextCap`.
- Tests: `RepoMetadataTests.swift:200` (cap), `:218` (floor), `:272` (non-positive raised to floor); a doc comment in `TranscriptNestingTests.swift:110`.

## Do this

1. Delete the three constants.
2. `nativeMaxContext` is the raw value of the first field present, in the order `max_position_embeddings`, `n_positions`, `max_seq_len`, `seq_length`. No clamp.
3. When no field is present, or the value is not positive, the metadata parse fails with a `RepoMetadataError` that names the repo and the four field names. Resolution then reports that candidate as unsized, the same way a missing `config.json` does today. Do not substitute a number.
4. Make the `init` parameter `nativeMaxContext` required. Every caller passes what it read.
5. Remove `nativeMaxContextDiagnostic`. With no clamp there is no difference to explain. If a caller prints it, print nothing.
6. `contextLadder` uses `nativeMaxContext` as the top rung with no cap.
7. Replace the three clamp tests with two: a missing field is an error that names the four fields; a non-positive value is an error. Fix the doc comment in `TranscriptNestingTests.swift`.

## Acceptance

- `rg 'nativeMaxContextFloor|nativeMaxContextCap|defaultNativeMaxContext|nativeMaxContextDiagnostic'` finds nothing.
- A `config.json` with `max_position_embeddings: 262144` gives `nativeMaxContext == 262144`. One with `max_position_embeddings: 10485760` gives 10,485,760. One with 2048 gives 2048.
- A `config.json` with none of the four fields makes that candidate unsized, with an error that names the repo and the four fields.
- All tests pass.

## Not in this card

`ProfileDefinition.defaultContext` (8,192) and the ladder rungs in `JointFit.ladderStepDowns` are open questions for the owner. See the limits inventory of 2026-09-22. #compaction #limits