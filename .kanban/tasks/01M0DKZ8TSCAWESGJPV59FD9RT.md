---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0e7gthzyafx7k17yayaqy82
  text: |-
    Research findings.

    - The tier choice is in `RoutedSessionActor.performAutoCompaction(prompt:budget:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift). Tier order: the profile flash slot, then the session's own model, then the deterministic pipeline. Hermetic tests for the tier order exist in Tests/FoundationModelsRouterTests/AutoCompactionTests.swift with stub containers.
    - No output names the model that wrote the summary. `CompactionResult` has `summary`, `summaryEntryId`, token counts, and `stagesApplied` only.
    - Places that pair the SmolLM-135M trio with a `budget:` opt-in: Examples/CompactionDemo uses `budget:` but its flash slot now holds GLM-4-9B (a capable model, changed by ^nwe0qt1, hazard measurement recorded in its doc comment). Examples/MultiModelGeneration holds SmolLM-135M in flash but has no `budget:` opt-in. The integration test AutoCompactionTriggerIntegrationTests uses Llama-3.2-1B, not SmolLM. No other place pairs the trio with `budget:`.

    Plan (per the card's decision list, option 1 plus a signal; no routing change):
    1. Add `summarizerModel: String?` to `CompactionResult` — the signal that names the model that wrote the summary. `RoutedSessionActor.fold` sets it from the tier that ran: flash slot's chosen ref, the session's own model ref, or nil for a deterministic fold. This makes the choice visible in each `.compaction(_:)` event.
    2. Document the quality hazard on `performAutoCompaction` and in compaction_plan.md §1.4.
    3. Add a caution note where MultiModelGeneration puts SmolLM-135M in flash, so a later `budget:` opt-in does not pair them blindly.
    4. TDD: extend the hermetic tier-choice tests to assert the new field for the flash tier, the own-model tier, and manual compact.
  timestamp: 2026-08-20T00:00:48.703318+00:00
- actor: claude-code
  id: 01m0e842w7xnw82g7vw3dm8eme
  text: |-
    Implementation complete. The card's decision list gave three options. I applied option 1 (document the hazard) and added a visible signal. I did not change the routing behavior.

    What changed:
    - `CompactionResult` has a new field `summarizerModel: String?` (Sources/FoundationModelsRouter/Compaction/Compactor.swift). It names the model that wrote `summary`. It is nil when there is no summary, and nil when the producer did not name one (bare `Compactor` calls, cold `SessionProjection` rows). An internal helper `namingSummarizerModel(_:)` applies the name only when a summary exists.
    - `RoutedSessionActor.fold` has a new `summarizerModel: ModelRef?` parameter (Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift). The tier call sites supply it: the flash tier passes `profile.flash.chosen`, the own-model tier and the manual `compact()` pass `model`, and the deterministic tier passes nil. The `.compaction(_:)` event now names the summary's writer.
    - The summary quality hazard is documented on `performAutoCompaction` (a "Summary quality hazard" section with the 2026-08-19 measurement) and in compaction_plan.md §1.4 (a matching note, plus `summarizerModel` in the `CompactionResult` sketch).
    - AC2 audit of the SmolLM-135M trio with a `budget:` opt-in: Examples/CompactionDemo pairs a budget with a capable flash model (GLM-4-9B, from ^nwe0qt1) and now prints `summarizerModel` in its checkpoint block. Examples/MultiModelGeneration holds SmolLM-135M in flash with no budget; a caution comment now points at the hazard so a later `budget:` addition does not pair them blindly. The integration tests use Llama-3.2-1B, not SmolLM. No other place pairs the trio with a budget.

    TDD: assertions on `summarizerModel` went into AutoCompactionTests (flash tier names "org/flash-a"; own-model fallback names "org/std-a") and RoutedSessionCompactTests (manual compact names "org/std-a"; a deterministic-only fold names nil). The three non-nil assertions failed before the wiring (RED observed, expectation failures on the new field) and pass after it.

    Verification: `Scripts/swift-test.sh --skip IntegrationTests` — 1021 tests in 96 suites passed (1 pre-existing known issue) plus 77 tests in 9 suites passed. `swift build --build-tests -Xswiftc -warnings-as-errors` — clean.
  timestamp: 2026-08-20T00:11:19.815607+00:00
- actor: claude-code
  id: 01m0e84c0zgx1nqxs01dqzgmey
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Compaction/Compactor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, compaction_plan.md, Examples/CompactionDemo/main.swift, Examples/MultiModelGeneration/main.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift. Tests: Scripts/swift-test.sh --skip IntegrationTests — 1021 + 77 passed, 0 failed; swift build --build-tests -Xswiftc -warnings-as-errors — clean.
    - next: review
  timestamp: 2026-08-20T00:11:29.183651+00:00
- actor: claude-code
  id: 01m0e87a955zvc6egsq9n9ateb
  text: |-
    ### test — green
    - evidence: `swift build --build-tests -Xswiftc -warnings-as-errors` build OK, no warnings, no errors. `Scripts/swift-test.sh --skip IntegrationTests` all pass: 1021 tests in 96 suites (1 known issue, this is the pre-existing BoundedWaitTests issue, this is OK), and 77 tests in 9 suites. No fail. No skip.
    - next: task can go to review.
  timestamp: 2026-08-20T00:13:05.701158+00:00
position_column: doing
position_ordinal: '8580'
title: Auto-compaction's flash summarizer tier degrades summary quality without a signal when the flash slot holds a tiny model
---
Found on 2026-08-19 while task ^nwe0qt1 rebuilt the CompactionDemo.

## What was measured

`RoutedSessionActor.performAutoCompaction(prompt:budget:)` prefers the profile's `flash` slot as the fold's summarizer tier. With `mlx-community/SmolLM-135M-Instruct-4bit` in `flash` — the placeholder trio the repo's demos use — every fold summary degenerated into hallucinated repetition loops. This happened with greedy decoding and with sampled decoding, with the default `CompactionPrompt` and with a simple one-paragraph prompt, and with three different `standard` models (Llama-3.2-1B, Qwen2.5-3B, Phi-3.5-mini). The same span and prompt through `mlx-community/GLM-4-9B-0414-4bit` produced a dense, accurate summary.

The degraded summaries pass every mechanical check: `stagesApplied` is non-empty, the transcript shrinks, and the checkpoint records. The only sign of the defect is the summary text, which no test reads. A session that resumes from such a fold reads garbage in place of its history.

## What to decide

1. Document that a profile which opts into auto-compaction must put a model that can summarize into `flash`, or
2. Add a guard or a heuristic (for example, a minimum parameter count, or skip the flash tier when flash is far smaller than standard), or
3. Change the tier order so the session's own model summarizes when flash is a placeholder.

## Acceptance criteria

- [x] The flash-tier summary quality hazard is documented on `performAutoCompaction` and on the compaction plan, or a guard makes the hazard unreachable
- [x] The demo trio (`SmolLM-135M` as flash) is checked in every place that pairs it with a `budget:` opt-in #compaction