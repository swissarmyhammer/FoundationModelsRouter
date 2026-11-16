---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: ProfileDefinition.choices(for:) gives one entry per model, also when only the drafter differs
---
## What
Defect found by ACPAgent 2379e94. When a slot names a reference in its text form (no drafter), and the builtin list (`ModelChoices`) has the same repo with its MTP drafter, `choices(for:)` gives the 27B model two times: once with and once without the drafter. The Settings Models pane then shows two rows for one model.

Fix: deduplicate by the model identity (repo or path, revision, file), not by the full `ModelRef` value. One entry for each model. When two entries differ only in the drafter, keep one entry at the position of the configured (profile) entry, and take the drafter of the builtin entry when the configured entry has none (the builtin entry knows the right drafter). When the configured entry has a drafter, keep it.

## Acceptance criteria
- [ ] Regression test: a profile slot with the default 27B as text form (no drafter) gives one 27B entry in `choices(for: .standard)`, at the first position, with the builtin MTP drafter.
- [ ] A configured entry with its own drafter keeps that drafter.
- [ ] Other entries keep their order; no copies.
- [ ] Full `swift test` green.

## Files
Sources/FoundationModelsRouter/Core/SlotModel.swift (`choices(for:)`), Tests/FoundationModelsRouterTests/ModelChoicesTests.swift. Find how `ModelRef` holds the repo, path, revision, file and drafter in Extras. #router-3