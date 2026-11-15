---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Allow one model in both the standard and the flash slot
---
## Problem
ACPAgent wants Flint in both standard and flash. `ProfileDefinition.sharedGenerationModel` / `SameGenerationModelFailure` (Router.rejectSharedGenerationModel) refuse it, and `JointFit` excludes the standard winner from flash (`Verdict.sameModelAsStandard`). The reason given is a deadlock: a sync flash call inside an open standard submission on one per-model FIFO queue.

## Why the reason no longer holds
505a03f3 (^qhgfajc, 2026-10-24) removed the whole-call GenerationQueue job: the MLX lock covers only the call into the model, a tool body holds nothing, and a child session on the same model generates while its parent's tool body waits.

## Change
- Remove `sharedGenerationModel`, `SameGenerationModelFailure`, `rejectSharedGenerationModel`, `Verdict.sameModelAsStandard`, and the flash `excluding:`.
- The flash slot gets the standard winner's pool key as an allocated key, so the same model costs 0 more bytes (as the decision slot does).
- Update the docs that cite the deadlock (JointFit, ProfileDefinition, SlotResolution).

## Done when
Hermetic tests: a profile with standard == flash resolves with one container and one charge; `swift test` green. #feature