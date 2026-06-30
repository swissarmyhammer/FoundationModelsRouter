---
comments:
- actor: wballard
  id: 01kwd046ycw0h784nbt76jjebt
  text: |-
    Implemented milestone 4a (pure joint-fit + diagnostics) TDD-style.

    Files:
    - Sources/FoundationModelsRouter/Resolution/SlotResolution.swift: Verdict enum (chosen/tooLarge/skippedHigherPreferenceChosen/metadataUnavailable(String)), CandidateReport, SlotResolution, ResolutionFailure (CustomStringConvertible description renders slots -> candidates -> footprints vs budget).
    - Sources/FoundationModelsRouter/Resolution/JointFit.swift: enum JointFit with static resolve(profile:budgetBytes:footprint:). Footprint injected as closure (ModelRef) -> Result<Int64, RepoMetadataError> (reuses existing RepoMetadataError.metadataUnavailable). x1.2 margin applied exactly once via withMargin() (ceil of raw*6/5, conservative); estimatedFootprintBytes is the scaled value. Allocation order embedding -> standard -> flash against shared budget; reserved amount is the scaled footprint so later slots see less budget. First viable in author preference order wins; never substitutes a quant. All three slots are always resolved (even on failure) so ResolutionFailure carries every slot's SlotResolution; unsatisfiable slot has chosen==nil.

    Design notes: budget reservation subtracts the x1.2 (scaled) footprint, consistent with the viability test, so the margin is applied once per candidate and never double-counted. Skipped lower-preference candidates are recorded with estimatedFootprintBytes==nil (not sized).

    Tests Tests/FoundationModelsRouterTests/JointFitTests.swift (8 tests, all injected footprints, no I/O): portability (32B on big budget, 14B on small, same profile); embedding-first reservation changes standard's pick; x1.2 reflected in report; inclusive x1.2 boundary (exact sum resolves, -1 throws); failure diagnostics shape (unsatisfiable slot chosen==nil, all tooLarge); description lists profile/budget/refs/footprints; metadataUnavailable skipped+recorded, next viable chosen.

    Build env: export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer. `swift test --filter JointFitTests` -> 8/8 pass. Full `swift test` -> 47 pass + 1 gated integration skipped. GREEN. Left in doing.
  timestamp: 2026-06-30T19:29:33.644784+00:00
- actor: wballard
  id: 01kwd0xz4kq8tq0azzvp9kek4s
  text: |-
    Addressed both 2026-06-30 14:34 review findings.

    1. JointFit.swift: removed the standalone `candidates(of:for:)` helper (single call site, no abstraction). `resolveSlot()` now accepts `profile: ProfileDefinition` directly and derives candidates inline via a switch expression. Behavior unchanged.
    2. JointFitTests.swift: extracted `private static let coderProfileName = "coder"` and referenced it in all three sites (ladderProfile name, profileName assertion, description assertion).

    Verified GREEN: `swift test --filter JointFitTests` → 8/8 pass; full `swift test` → 47 tests pass + gated integration suite (1 skipped).
  timestamp: 2026-06-30T19:43:37.619627+00:00
- actor: wballard
  id: 01kwd1mbvhjh3j9vbt47c5g85c
  text: |-
    Resolved review finding (2026-06-30 14:46): made the slot→candidates mapping data-driven.

    - Added a total computed property `candidatesBySlot: [ModelSlot: [ModelRef]]` on `ProfileDefinition` returning `[.standard: standard, .flash: flash, .embedding: embedding]` (one entry per ModelSlot case; each list keeps the author's preference order).
    - `JointFit.resolveSlot()` now does `let candidates = profile.candidatesBySlot[slot] ?? []`, replacing the 3-arm `switch slot`.

    No new smell: genuine dictionary + keyed lookup (not a relocated switch), no force-unwrap. The `?? []` is a never-taken fallback since the map is total over all three ModelSlot cases. Behavior byte-for-byte identical.

    Verification: `swift test --filter JointFitTests` -> 8/8 green; full `swift test` -> 47 tests/9 suites green + integration target. double-check agent verdict: PASS. Finding checked off; task left in `doing` for /review.
  timestamp: 2026-06-30T19:55:51.537384+00:00
depends_on:
- 01KWC5C3B35X6N0DYZJYZ044BE
- 01KWC5CQ49ZCF1VVP9FW6T4QZF
position_column: doing
position_ordinal: '80'
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

## Review Findings (2026-06-30 14:34)

- [x] `Sources/FoundationModelsRouter/Resolution/JointFit.swift:133` — The `candidates()` function wraps a single call site (line 99) with a simple switch statement that adds no meaningful abstraction beyond naming. The switch could be inlined or the caller could directly access the profile properties. Inline the switch statement or modify `resolveSlot()` to accept the profile directly instead of pre-extracted candidates. RESOLVED: removed the standalone `candidates(of:for:)` helper; `resolveSlot()` now takes `profile: ProfileDefinition` and computes its candidates inline via a switch expression. Behavior identical.
- [x] `Tests/FoundationModelsRouterTests/JointFitTests.swift:60` — The string literal "coder" appears three times as a test constant (the profile name) and is checked in multiple test assertions. This meets the rule-of-three threshold for extracting a named constant so changes occur in one place. Extract "coder" as a private static let constant at the top of the test suite, e.g., `private static let coderProfileName = "coder"`, and reference it in all three locations (the profile definition and both assertions). RESOLVED: added `private static let coderProfileName = "coder"` and replaced all three occurrences (profile definition, profileName assertion, description assertion).

## Review Findings (2026-06-30 14:46)

- [x] `Sources/FoundationModelsRouter/Resolution/JointFit.swift:115` — The switch statement maps from a known enum (ModelSlot) to properties of the ProfileDefinition struct. This is a match over a known set with arms that differ only in which property is accessed—a pattern that should be expressed as data rather than as parallel code paths a human must keep in lockstep. Extract this mapping as data: replace the switch with a dictionary lookup. For example: `let slotCandidates: [ModelSlot: [ModelRef]] = [.embedding: profile.embedding, .standard: profile.standard, .flash: profile.flash]` followed by `let candidates = slotCandidates[slot]!`. RESOLVED: added a total computed `candidatesBySlot: [ModelSlot: [ModelRef]]` mapping on `ProfileDefinition` (`[.standard: standard, .flash: flash, .embedding: embedding]` — one entry per `ModelSlot` case, each preserving the author's order) and changed `resolveSlot()` to `let candidates = profile.candidatesBySlot[slot] ?? []`. The mapping is genuine data (dictionary + keyed lookup), not a relocated switch; no force-unwrap (the `?? []` is a never-taken safety net since the map is total). Behavior byte-for-byte identical. `swift test --filter JointFitTests` 8/8 green; full `swift test` green.