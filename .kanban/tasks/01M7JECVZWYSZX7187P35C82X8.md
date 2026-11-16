---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jetwaztr9y9gaz7rdbpqfm
  text: |-
    Research: ModelRef (Extras, ModelPool/ModelRef.swift) holds repo, path (the GGUF file or folder) and revision; init(repo:path:revision:drafter:) normalizes the path and changes the revision "main" to nil. The drafter is stored as parts and is part of Hashable, so the old Set<ModelRef> dedup kept the text form and the builtin form of the 27B model as two choices.

    Fix: choices(for:) deduplicates on a fileprivate `ModelRef.withoutDrafter` (repo, path, revision). The first reference of a model keeps its position. When it has no drafter, it takes the drafter of the first later reference of the same model that has one (the builtin entry). A reference with its own drafter keeps it. Doc comment of choices(for:) updated (the old text said that a drafter difference gives two choices).

    TDD: 4 new tests in ModelChoicesTests. RED: 3 failed as expected; "keeps its own drafter" passed before the fix (the old first-wins dedup already kept it) and stays as an acceptance guard. GREEN: 21/21 ModelChoices tests + 3 public-surface tests.

    Full `swift test` one time: 2810 tests in 328 suites passed, plus 45 and 19; exit 0. The only warning is the SwiftPM "missing creator for mutated node" warning for the mlx-swift_Cmlx bundle. It is a build-system warning that was there before this change, not a compiler warning.
  timestamp: 2026-11-16T15:15:28.735762+00:00
- actor: claude-code
  id: 01m7jev2f84419avte7p2tm2v4
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Core/SlotModel.swift, Tests/FoundationModelsRouterTests/ModelChoicesTests.swift; `swift test --filter ModelChoices` 21 + 3 passed; full `swift test` 2810/328 suites + 45 + 19 passed, exit 0
    - next: /review
  timestamp: 2026-11-16T15:15:35.016432+00:00
- actor: claude-code
  id: 01m7jex3pcj5x80j559qvkx3qm
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (ffe87391); 0 findings (0 confirmed, 0 refuted); no prior findings
    - next: none. The task is in done.
  timestamp: 2026-11-16T15:16:41.804318+00:00
position_column: done
position_ordinal: ffffffffffa380
title: ProfileDefinition.choices(for:) gives one entry per model, also when only the drafter differs
---
## What
Defect found by ACPAgent 2379e94. When a slot names a reference in its text form (no drafter), and the builtin list (`ModelChoices`) has the same repo with its MTP drafter, `choices(for:)` gives the 27B model two times: once with and once without the drafter. The Settings Models pane then shows two rows for one model.

Fix: deduplicate by the model identity (repo or path, revision, file), not by the full `ModelRef` value. One entry for each model. When two entries differ only in the drafter, keep one entry at the position of the configured (profile) entry, and take the drafter of the builtin entry when the configured entry has none (the builtin entry knows the right drafter). When the configured entry has a drafter, keep it.

## Acceptance criteria
- [x] Regression test: a profile slot with the default 27B as text form (no drafter) gives one 27B entry in `choices(for: .standard)`, at the first position, with the builtin MTP drafter.
- [x] A configured entry with its own drafter keeps that drafter.
- [x] Other entries keep their order; no copies.
- [x] Full `swift test` green.

## Files
Sources/FoundationModelsRouter/Core/SlotModel.swift (`choices(for:)`), Tests/FoundationModelsRouterTests/ModelChoicesTests.swift. Find how `ModelRef` holds the repo, path, revision, file and drafter in Extras. #router-3