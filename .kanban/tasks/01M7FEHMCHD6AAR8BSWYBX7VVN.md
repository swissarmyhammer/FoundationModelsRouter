---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ff8s8dm7fmmh4b9wqq9py1
  text: |-
    ### commit — changed
    - evidence: 119e7ba8 fix(resolution)!: the decision slot always gets its decision model; `swift test` 2716 + 42 + 19 green; `swift build --package-path IntegrationTests --build-tests` clean.
    - note: the decision model is sized at the context of the other slots (a GGUF decision model's KV grows with the window). Kept as before. A decision container that cannot answer on its path still resolves and throws at the first decision (UnavailableDecisionContainer); not a flash fallback, left as is.
  timestamp: 2026-11-15T11:25:21.037231+00:00
position_column: done
position_ordinal: ffffffffff9680
title: 'The decision slot always gets its decision model: no flash fallback, fail resolve when it cannot fit'
---
## Problem
ACPAgent flint24 (Router a6ebd195): profile standard flint-oQ8e, flash Qwen3-4B-4bit, embedding embeddinggemma, decision = defaultDecisionCandidates (h2o-lightning-4b GGUF). The resolve span says `model.ref.decision = mlx-community/Qwen3-4B-4bit` (flash). Budget 83,494,174,720 B, pool resident after the trio 83,184,773,461 B. No warning, no verdicts, h2o never downloaded.

## Cause (confirmed in code)
`JointFit.resolveAtLargestWindow` → `searchWindow`/`computedWindow` grows the trio's window until the trio fills the whole budget. `resolveDecision` runs after, on `flash.remainingBudgetBytes` ≈ 0, so every decision candidate is `tooLarge`, and `SlotResolution.flashFallback` silently picks flash. With a derived context the decision slot nearly always falls back.

## Requirement (user, via ACPAgent, 2026-11-15)
"decision falling back to flash isn't acceptable". No silent fallback and no fallback to flash at all.
- The decision slot is a required fourth slot. It is fitted inside the trio attempt, so the window search sizes the four models together, and the decision model gets its bytes before the window grows (the others shrink).
- If no decision candidate fits even at the smallest window, resolve fails with `ResolutionFailure` that names the slots and footprints.
- Remove `SlotFallback.flashModel`, `JointResolution.fallingBackToFlash`, `SlotResolution.flashFallback`. A failed read of `decider_config.json` (`DecisionSlotPlan`) fails resolve instead of falling back.
- A decision candidate that a trio winner's pool key serves still costs 0 more bytes.
- A profile with no decision candidate fails resolve (validation).

## Done when
Hermetic unit tests: derived context leaves room for the decision model; a decision model that cannot fit fails resolve with a report naming it; decider-config read failure fails resolve. `swift build --build-tests`, `swift test` green. #bug