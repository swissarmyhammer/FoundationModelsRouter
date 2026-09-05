---
assignees:
- claude-code
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
position_column: todo
position_ordinal: '8380'
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