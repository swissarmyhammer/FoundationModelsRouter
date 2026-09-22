---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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