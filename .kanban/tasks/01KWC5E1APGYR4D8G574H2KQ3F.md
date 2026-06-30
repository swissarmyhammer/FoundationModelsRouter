---
depends_on:
- 01KWC5C3B35X6N0DYZJYZ044BE
- 01KWC5CQ49ZCF1VVP9FW6T4QZF
position_column: todo
position_ordinal: '8780'
title: Joint-fit resolution algorithm + diagnostics types (milestone 4a)
---
## What
The pure allocation that picks the highest-preference *combination* of three slots that co-fits one budget, plus the diagnostic types it produces. No network, no MLX — given a function `ModelRef -> footprint` (or `metadataUnavailable`). Plan "Resolution (joint)".

- `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`:
  - `struct CandidateReport { ref; estimatedFootprintBytes: Int64? /* already ×1.2 */; verdict }` with `enum Verdict { chosen, tooLarge, skippedHigherPreferenceChosen, metadataUnavailable(String) }`.
  - `struct SlotResolution { slot; remainingBudgetBytes: Int64; chosen: ModelRef?; considered: [CandidateReport] }`.
  - `struct ResolutionFailure: Error { profileName; budgetBytes; slots: [SlotResolution] }` with a `description` rendering slots → candidates → footprints vs budget.
- `Sources/FoundationModelsRouter/Resolution/JointFit.swift`:
  - The fit margin: a candidate is viable in `remaining` iff `footprint * 1.2 <= remaining` (the ×1.2 lives HERE, not in `Footprint`).
  - Allocate in preference order against the shared budget: **embedding** (first viable; reserve its footprint) → **standard** (largest viable in `budget − embedding`) → **flash** (largest viable in `budget − embedding − standard`).
  - "Largest viable" = first viable in author's preference order (biggest/best first); never substitute a quant the author didn't list — only accept or skip.
  - If any slot has no viable candidate in what's left ⇒ throw `ResolutionFailure` carrying every slot's `SlotResolution` (candidates, footprints, budget).
  - On success return the chosen trio + per-slot `SlotResolution` (with `considered` reports incl. skipped/tooLarge reasons).

## Acceptance Criteria
- [ ] On a budget where the 32B-8bit fits, standard chooses it; on a smaller budget it falls through to 4-bit then 14B per author order, with skipped candidates marked `tooLarge`.
- [ ] Allocation order is embedding → standard → flash, each against the remaining budget (later slots see less budget).
- [ ] ×1.2 margin is applied exactly once at the fit comparison; `CandidateReport.estimatedFootprintBytes` reflects the ×1.2 value.
- [ ] A profile that cannot co-fit throws `ResolutionFailure` whose `description` lists each slot's considered candidates, footprints, and the budget; the unsatisfiable slot has `chosen == nil`.
- [ ] `metadataUnavailable` candidates are skipped (recorded as such), not chosen.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/JointFitTests.swift` (Swift Testing): portability case (same profile → 32B on big budget, 14B on small budget); embedding-first reservation reduces budget for standard/flash; ×1.2 boundary; failure diagnostics shape; metadataUnavailable skipping. All with injected footprints — no I/O.
- [ ] Run `swift test --filter JointFitTests` — all pass.

## Workflow
- Use `/tdd` — write failing allocation + diagnostics tests with injected footprints first.