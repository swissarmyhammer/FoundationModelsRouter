---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7yye46snd3dtspvzwtjce3k
  text: |-
    Implementation done.
    - ProfileDefinition.swift: new constants defaultDescription (""), defaultStandardCandidates (Qwen3.5-9B-4bit with drafter Qwen3.5-9B-MTP-4bit, written as ModelRef(repo:drafter:) the same as ModelChoices.generation), defaultEmbeddingCandidates (erjigit17/embeddinggemma-300m-ane-coreml). The init parameters description, standard and embedding have defaults, and flash is `[ModelRef]? = nil` (nil gives standard). The decoder reads the 4 keys with decodeIfPresent; name stays required. encode(to:) did not change. The type, init and decoder docs now say that only `name` is required, and they list each default.
    - Callers: all `ProfileDefinition(...)` calls in Sources, Tests, Tools (RecordCompactionFixture is a root target) and IntegrationTests pass all arguments, so they compile with no change and keep their behavior. `swift build --build-tests` in IntegrationTests: Build complete.
    - Tests: 14 new tests in Tests/FoundationModelsRouterTests/CoreTypesTests.swift, next to the existing ProfileDefinition Codable tests (constants, init with only name, init flash nil, decode only name, each of 4 keys alone, standard alone also sets flash, missing name throws, round trip for fp16 and bits8).
    - Not done here: the card says "Send the sha to foundationmodelsacpagent-9e after the push". No commit was made (the instruction for this step was not to commit), so that step stays for the commit/push step.
  timestamp: 2026-11-21T11:39:01.209507+00:00
- actor: claude-code
  id: 01m7yye6rtrgnbn2wsj0be2ckq
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Core/ProfileDefinition.swift, Tests/FoundationModelsRouterTests/CoreTypesTests.swift. RED: build failed on missing members. GREEN: CoreTypesTests 23/23 pass. Full `swift test` one run: 3262 tests in 364 suites passed, 54 in 28 passed, 19 in 3 passed, 0 failures. IntegrationTests `swift build --build-tests`: Build complete.
    - next: review; after commit and push, send the sha to foundationmodelsacpagent-9e.
  timestamp: 2026-11-21T11:39:03.834503+00:00
position_column: doing
position_ordinal: '80'
title: Code defaults for standard, flash, embedding and description in ProfileDefinition
---
User decision 2026-11-21 (request from foundationmodelsacpagent-9e, its card ^f4z8wj9): a profile must not take its missing keys from the bundled `large` profile. The defaults go in `ProfileDefinition` (`Sources/FoundationModelsRouter/Core/ProfileDefinition.swift`), in one place, consistent with the existing defaults (`decision`, `context`, `decisionContext`, `kvBits`).

Decisions (Router):
- `standard`: a new constant `defaultStandardCandidates`, with a doc comment. The model is `mlx-community/Qwen3.5-9B-4bit` with the drafter `mlx-community/Qwen3.5-9B-MTP-4bit` (the model of the bundled `small` profile). The agent needs 16 GB or more, and this model fits that minimum, so the default works on each supported Mac. The name and the doc tell what the model is, not "the large profile".
- `flash`: when the key is absent, the `standard` list of the same definition (the decoded one, or the default). In `init`, the parameter is `flash: [ModelRef]? = nil`, and `nil` gives `standard`. The property stays `[ModelRef]`.
- `embedding`: a new constant `defaultEmbeddingCandidates` = [`erjigit17/embeddinggemma-300m-ane-coreml`].
- `description`: a new constant `defaultDescription` = "" (empty text).
- `name` stays required. ACPAgent always sets it from the name of the file.
- `kvBits` absent stays fp16. `encode(to:)` writes all keys as today (no `kvBits` for fp16, no `context` for nil). Encode then decode gives the same definition.

- [x] Add the constants with doc comments, and init parameter defaults in the same style as `decision`.
- [x] Decode each of the 4 keys with `decodeIfPresent` and the default.
- [x] Update the type doc and the init / decoder docs (which keys are required: only `name`).
- [x] Look at the code that calls `ProfileDefinition(...)` in Sources, Tests, IntegrationTests and Tools. Keep them compiling. Do not change their behavior.
- [x] Tests: a map with only `name` decodes to all defaults (flash == standard default); each of the 4 keys alone overrides only itself (and `standard` alone also gives that list to `flash`); round trip encode/decode for fp16 and for 8-bit.
- [x] `swift test` passes (one full run).

Send the sha to foundationmodelsacpagent-9e after the push.