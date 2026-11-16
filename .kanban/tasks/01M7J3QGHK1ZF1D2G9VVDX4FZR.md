---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7j96yjnad9t1eqj5xhcack1
  text: |-
    Research done.
    - Extras in .build is 65543a6; Package.resolved (gitignored) names 65543a6e. No update needed.
    - Router has no default for standard/flash/embedding. The default Qwen3.8-27B-4bit + MTP drafter (mlx-community/Qwen3.8-27B-MTP-4bit) is ProfileConfiguration.defaultStandard in FoundationModelsACPAgent. Default embedding there: erjigit17/embeddinggemma-300m-ane-coreml. Decision: ProfileDefinition.defaultDecisionCandidates.
    - Smaller standard models that the code already names: mlx-community/Qwen3-14B-4bit (Router docs/decision.md standard), mlx-community/Qwen3-8B-4bit (Extras REFERENCE.md), mlx-community/Qwen3-4B-4bit (Router RecordCompactionFixture flash, ACPAgent ProfileDoctor.smallerModel for 16 GB). Embedding alt: mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ (RecordCompactionFixture).
    - ACPAgent already has its own ModelsEngine / ModelStorageReading (per-ref storageInfo) and extends ModelSlot with @retroactive CaseIterable. To not break ACPAgent: the Router seam uses another name (ModelStorageSource) and Router adds no CaseIterable to ModelSlot.
    - Part 4: Router keeps no profile. resolve(profile:) reads the candidates one time; RoutedModel.chosen is a let; each session holds the LanguageModelProfile it was made from. A slot change applies at the next resolve; ACPAgent resolves at launch (RoutedACPAgent init), so the next launch.
    - ModelStorage's URLSession init is internal, so tests use a fake ModelStorageSource, plus one test of the ModelStorage conformance over a local folder ref (no network).
  timestamp: 2026-11-16T13:37:12.789843+00:00
- actor: claude-code
  id: 01m7j9fd8kr11pmhfhamgk2nxg
  text: |-
    ### implement — changed
    - evidence: 3 new source files (Core/SlotModel.swift, Core/ModelChoices.swift, Core/ModelStorageSummary.swift), 3 new test files (ModelChoicesTests 17 tests, ModelStorageSummaryTests 17 tests, ModelChoicesPublicSurfaceTests 3 tests). RED was a compile failure (API missing). `swift test --filter "ModelChoicesTests|ModelStorageSummaryTests|ModelChoicesPublicSurfaceTests"` ran 34 + 3 tests. Full `swift test` one time: 2802 tests in 326 suites + 45 + 19 passed, exit 0, no new compiler warning (only the old "missing creator for mutated node" build-system line).
    - API: SlotModel(slot:ref:) with ref, drafter, ggufFile; ProfileDefinition.slotModel(for:) -> SlotModel?; ProfileDefinition.choices(for:) -> [ModelRef]; ModelChoices.generation / .embedding / .decision / builtin(for:); protocol ModelStorageSource { storageInfo(of: ModelRef) }, ModelStorage conforms; ModelStorageSource.storageSummary(of:) -> ModelStorageSummary (model, drafter, totalBytes, presentBytes, diskBytes, state, ref, ggufFile).
    - Smaller standard choices: Qwen3-14B-4bit, Qwen3-8B-4bit, Qwen3-4B-4bit (all named in the code already). Sizes in the doc are approximate; no test measures them (no network).
    - Follow-up for the ACPAgent board (not this repo): ModelsEngine can drop its own builtin choices, its combined state and its ModelStorageReading, and call these. Its ModelsEngine.state differs: it gives `missing` when no byte is on disk; this API gives `missing` only when each part is missing.
    - next: /review
  timestamp: 2026-11-16T13:41:49.971730+00:00
- actor: claude-code
  id: 01m7j9j1c3yd9ec2574hjw7wxc
  text: |-
    ### implement — changed
    - evidence: the doc comments of Core/ModelChoices.swift no longer give GB sizes (16.1/0.3/8.3/4.6/2.3 GB, 32 GB and 16 GB machine). The doc now says that each standard choice after the default is a smaller model than the default, and that storageSummary(of:).totalBytes gives the size at run time. The test name "a model for a 16 GB machine" is now "the smallest Qwen3 4-bit model". A check of the whole diff found no other number from memory; the test numbers (1_000, 30, 400) are fixture values. `swift test --filter ModelChoices`: 17 + 3 tests passed. The build had no new warning.
    - next: /review
  timestamp: 2026-11-16T13:43:16.099701+00:00
- actor: claude-code
  id: 01m7j9sc64qt5kh0kqdxrjxn86
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (1a2ee949); 0 findings (0 confirmed, 4 refuted); no prior findings
    - next: none. The task is in done.
  timestamp: 2026-11-16T13:47:16.548410+00:00
depends_on:
- 01M7J2Z8PTQ4Q7J3C20B5CP7V3
position_column: done
position_ordinal: ffffffffffa080
title: Model choices of each slot for the Settings Models pane (TestudoApp ^453zgr3, D183 (c))
---
## What
An in-process API of Router that a host can call BEFORE `ComposedAgent.compose` and before any download. ACPAgent puts it on a `models` GraphQL endpoint.

1. The resolved model of each slot of a profile (`standard`, `flash`, `embedding`, `decision`): the `ModelRef`, its drafter ref if any, and the GGUF file if any.
2. `choices(for slot)`: the models that the slot can take. Router owns this list; the app has none. The `standard` list has one or more models that are smaller than the default (Qwen3.8-27B-4bit is 16.1 GB + 0.3 GB drafter). Use the profile candidates (for example `ProfileDefinition.defaultDecisionCandidates` for decision).
3. A helper that gives, for a slot row or a choice, the storage info of the model and its drafter together (sum of `totalBytes`, combined state), through `ModelStorage` of Extras 65543a6: `ModelStorage(cacheDirectory:tokenProvider:)`, `storageInfo(of: [ModelRef]) async throws -> [ModelStorageInfo]` (ref, revision, files, totalBytes: Int64?, presentBytes, diskBytes, state: `ModelDiskState` complete/partial/missing). It makes no download. The MTP drafter is NOT in the file set of its ref: give the drafter as its own ref.
4. Document whether a change of `profile.<slot>` applies to the next session or only to the next launch of the agent.

## Acceptance criteria
- [x] The four parts above, public, with tests that need no network and no GPU.
- [x] Combined state: complete only when the model and the drafter are complete; missing when both are missing; else partial. totalBytes is nil when one part is nil.
- [x] Package.resolved has Extras 65543a6 or later.
- [x] Doc comment states when a change of a slot applies.

## Notes
Find the profile and slot code in `Sources/FoundationModelsRouter/LanguageModelProfile.swift`, `Sources/FoundationModelsRouter/Resolution/`, and `ProfileDefinition`. #router-3