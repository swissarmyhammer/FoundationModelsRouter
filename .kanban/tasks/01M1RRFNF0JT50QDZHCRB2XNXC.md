---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1rydrnbzd9ra74aktfqv1bw
  text: |-
    ### research
    - `ResidencyKey.Role.llm(context:)` was built at two sites in `Sources/FoundationModelsRouter/Router.swift`: the acquisition loop (`.llm(context: slotRes.contextTokens)`) and `footprintBytes(for:context:metadataByRef:membership:residentKeys:)` (`.llm(context: context)`). No test built a `ResidencyKey` by hand.
    - `LiveModelLoader.loadLLM(ref:slot:context:reporting:)` does not read `context`. The KV cache is priced per session already: `footprintBytes` charges a resident generation model `sessionKV` at the resolve's own context, and `JointFit.sessionBytes` charges a slot that reuses an earlier slot. Only the key lookup changed. Every charge is as it was.
    - Margin arithmetic for the new budget pin, from `JointFit.withMargin` (`ceil(raw × 6 / 5)`) and the canned 2-layer config (`kvHeads` 2, `headDim` 16): KV cache at 4096 tokens is raw 1_048_576 bytes, margined 1_258_292. A generation model at 4096 tokens is raw 11_048_576, margined 13_258_292. These are the new `ResidencyFixtures` constants.
    - RED was confirmed before the code change: `sameRepoDifferentContextSharesOneContainer` saw two loads for `org/ctx-repo`; `secondContextChargesOnlyItsOwnSessionKVCache` could not fit the narrow profile (budget 14_517_584 bytes) because the reused generation model was charged its full weights.
  timestamp: 2026-09-05T14:09:11.851788+00:00
- actor: claude-code
  id: 01m1rye9s3z1jyd5jh2xqja2sr
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Resolution/ModelPool.swift (`Role.llm` has no associated context; doc comment), Sources/FoundationModelsRouter/Router.swift (two key sites build `.llm`; `footprintBytes` and `acquireLLM` doc comments), Sources/FoundationModelsRouter/Resolution/ModelLoader.swift (`loadLLM(context:)` doc comment: advisory), Tests/FoundationModelsRouterTests/Helpers/ResidencyStubs.swift (`steppedDownContext` doc comment; three new stepped-down byte constants), Tests/FoundationModelsRouterTests/PooledResidencyTests.swift (`sameRepoDifferentContextDoesNotShare` replaced by `sameRepoDifferentContextSharesOneContainer`; new `secondContextChargesOnlyItsOwnSessionKVCache`; `expectNoRoomLeft` helper; suite doc comment)
    - next: test
  timestamp: 2026-09-05T14:09:29.379190+00:00
- actor: claude-code
  id: 01m1ryff436pdv612d2a9af4vr
  text: |-
    ### test — green
    - evidence: `swift test` — 1228 tests in 133 suites passed, plus 83 tests in 10 suites passed; 0 failures, 0 skipped, 0 new warnings. The two "known issue" marks are the pre-existing `withKnownIssue` blocks in `BoundedWait` and `RealModelHarness`; this card does not touch them.
    - next: commit
  timestamp: 2026-09-05T14:10:07.619933+00:00
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
position_column: doing
position_ordinal: '80'
title: Drop the working context from the generation residency key
---
Plan: `model-pool.md` §1.3, §2.3.

## What
`ResidencyKey.Role.llm(context:)` keys a generation model by its working context. The live loader never reads that context: `LiveModelLoader.loadLLM(ref:slot:context:reporting:)` in `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` builds `MLXLanguageModel` from the ref alone, and the MLX layer allocates the KV cache per generate call. So one model at two contexts is one set of weights, and the router charges the weights two times.

- In `Sources/FoundationModelsRouter/Resolution/ModelPool.swift`, make `ResidencyKey.Role` `.llm` and `.embedding` with no associated context.
- In `Router.swift`, build keys without the context, and in `footprintBytes(for:context:metadataByRef:membership:residentKeys:)` charge a resident generation model its session KV cache at the resolve's own context (this is what it does now; only the key lookup changes).
- Update the doc comments on `ResidencyKey`, `PooledResidencyTests.steppedDownContext`, and `ModelLoader.loadLLM(context:)` in `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`: the `context` parameter is advisory, and a loader must not size a container by it.
- Keep `JointFit.ReservationKey` as it is; it carries no context already.

## Acceptance Criteria
- [ ] One profile at the default context and one at 4096 tokens that name one generation model load it one time.
- [ ] The second profile is charged one session KV cache at its own context and zero weights. Pin this through the `budgetBytes` a failing third resolve reports, as `reusingResidentGenerationModelChargesOneSessionKVCache` does.
- [ ] `sameRepoDifferentContextDoesNotShare` is replaced by `sameRepoDifferentContextSharesOneContainer`; no test asserts two loads for one ref at two contexts.
- [ ] `swift test` → all pass.

## Tests
- [ ] `PooledResidencyTests.sameRepoDifferentContextSharesOneContainer`: one load for `org/ctx-repo`, both profiles answer.
- [ ] `PooledResidencyTests.secondContextChargesOnlyItsOwnSessionKVCache`: budget pin with the KV bytes of the canned config at 4096 tokens.
- [ ] Run `swift test --filter PooledResidencyTests` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #router