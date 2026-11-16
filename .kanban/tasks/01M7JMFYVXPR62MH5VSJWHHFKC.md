---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jmrsp6930nqrpa13e4bvmw
  text: |-
    Research: ModelChoices.generation already holds the four generation refs in table order (large has the MTP drafter). ModelChoices.embedding[0] is the Core ML embedding model. ProfileDefinition.init has defaults for decision, context and decisionContext. ModelSlot is not CaseIterable. The DocC catalog (FoundationModelsRouter.docc/FoundationModelsRouter.md) does not list ModelChoices. Thus ModelProfiles goes in the "Profiles" topic, after ProfileDefinition.

    Implementation: ModelProfiles.builtin zips a private list of (name, description) with ModelChoices.generation. Thus the generation refs come from one list only. The embedding slot is Array(ModelChoices.embedding.prefix(1)). named(_:) uses an exact (case-sensitive) match, because a profile name is an identifier. The doc comment tells this. The descriptions do not state sizes.

    TDD: RED was a compile failure ("cannot find 'ModelProfiles' in scope"). GREEN: `swift test --filter ModelProfiles` ran 16 tests in suite "Builtin model profiles" and 2 tests in suite "Model profiles over a plain import". All passed, with no warnings.
  timestamp: 2026-11-16T16:59:11.942982+00:00
- actor: claude-code
  id: 01m7jmrx1sx782q72c9ydh5m2t
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Core/ModelProfiles.swift (new), Tests/FoundationModelsRouterTests/ModelProfilesTests.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/ModelProfilesPublicSurfaceTests.swift (new), Sources/FoundationModelsRouter/FoundationModelsRouter.docc/FoundationModelsRouter.md. Full `swift test` one run: exit 0; Swift Testing 2826 tests in 329 suites, 47 tests in 25 suites, 19 tests in 3 suites passed; XCTest 0 tests; 0 failures; no compiler warnings (only the SwiftPM "missing creator for mutated node" build note, which is not from this change).
    - next: /review. The task stays in doing. No commit.
  timestamp: 2026-11-16T16:59:15.385040+00:00
position_column: doing
position_ordinal: '80'
title: 'ModelProfiles: four builtin named profiles (ROUTER-12, D189)'
---
## Goal
Add the public enum `ModelProfiles` in `Sources/FoundationModelsRouter/Core/ModelProfiles.swift`. Router owns the profile definitions. A host keeps no list of its own. Source: TestudoApp ec3296d, features/packages/foundationmodels-router.md ROUTER-12 and features/decisions.md D189.

## API
- `public static let builtin: [ProfileDefinition]`: four profiles, from the largest to the smallest.
- `public static let defaultName: String` = "large".
- `public static func named(_ name: String) -> ProfileDefinition?`.

| name | standard and flash | embedding | decision |
|---|---|---|---|
| large (default) | mlx-community/Qwen3.8-27B-4bit, drafter mlx-community/Qwen3.8-27B-MTP-4bit | erjigit17/embeddinggemma-300m-ane-coreml | ProfileDefinition.defaultDecisionCandidates |
| medium | mlx-community/Qwen3-14B-4bit | same | same |
| small | mlx-community/Qwen3-8B-4bit | same | same |
| tiny | mlx-community/Qwen3-4B-4bit | same | same |

- Each profile has one candidate in each slot. `flash` names the model of `standard` (with the same drafter), so the resolve loads it one time.
- Each profile has a description of one sentence. Router writes the descriptions. Do not state sizes in GB.
- Each profile has `decisionContext` = `ProfileDefinition.defaultDecisionContext`. `context` stays nil.
- Reuse the refs of `ModelChoices` where possible, so that the two lists do not drift. Do not remove `ModelChoices` now.

## Tests (TDD, Swift Testing, no .timeLimit)
- [x] builtin has the four profiles of the table in this order, with unique names.
- [x] Each slot of each profile is not empty; flash equals standard; the drafter of large is the MTP model.
- [x] Each description is one sentence and not empty.
- [x] named(_:) finds each profile; an unknown name gives nil; defaultName is "large" and named(defaultName) is not nil.
- [x] decisionContext of each profile is defaultDecisionContext.
- [x] Add the new public names to the public surface test if the repo has one (see ModelChoicesPublicSurfaceTests).
- [x] DocC: add the new type to the topics of the catalog where ModelChoices is listed. #router-12