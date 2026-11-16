---
assignees:
- claude-code
depends_on:
- 01M7J2Z8PTQ4Q7J3C20B5CP7V3
position_column: todo
position_ordinal: '8380'
title: Model choices of each slot for the Settings Models pane (TestudoApp ^453zgr3, D183 (c))
---
## What
An in-process API of Router that a host can call BEFORE `ComposedAgent.compose` and before any download. ACPAgent puts it on a `models` GraphQL endpoint.

1. The resolved model of each slot of a profile (`standard`, `flash`, `embedding`, `decision`): the `ModelRef`, its drafter ref if any, and the GGUF file if any.
2. `choices(for slot)`: the models that the slot can take. Router owns this list; the app has none. The `standard` list has one or more models that are smaller than the default (Qwen3.8-27B-4bit is 16.1 GB + 0.3 GB drafter). Use the profile candidates (for example `ProfileDefinition.defaultDecisionCandidates` for decision).
3. A helper that gives, for a slot row or a choice, the storage info of the model and its drafter together (sum of `totalBytes`, combined state), through `ModelStorage` of Extras 65543a6: `ModelStorage(cacheDirectory:tokenProvider:)`, `storageInfo(of: [ModelRef]) async throws -> [ModelStorageInfo]` (ref, revision, files, totalBytes: Int64?, presentBytes, diskBytes, state: `ModelDiskState` complete/partial/missing). It makes no download. The MTP drafter is NOT in the file set of its ref: give the drafter as its own ref.
4. Document whether a change of `profile.<slot>` applies to the next session or only to the next launch of the agent.

## Acceptance criteria
- [ ] The four parts above, public, with tests that need no network and no GPU.
- [ ] Combined state: complete only when the model and the drafter are complete; missing when both are missing; else partial. totalBytes is nil when one part is nil.
- [ ] Package.resolved has Extras 65543a6 or later.
- [ ] Doc comment states when a change of a slot applies.

## Notes
Find the profile and slot code in `Sources/FoundationModelsRouter/LanguageModelProfile.swift`, `Sources/FoundationModelsRouter/Resolution/`, and `ProfileDefinition`. #router-3