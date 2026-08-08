---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Gated compaction suites never reach the 0.80 trigger on real hardware — live contextFill contradicts hermetic sizing
---
Discovered by `^ce4hb6n`, which removed the `default.metallib` abort and so let these assertions execute against real hardware for the FIRST time. Nothing here is a regression — this is behavior that was never observable before. No assertion was changed to accommodate it.

Measured on 2026-08-08, `FM_ROUTER_INTEGRATION_TESTS=1 swift test`, model `mlx-community/Qwen3.6-27B-mxfp4`.

## One root cause, three failing suites

Compaction never fires against the real model, because measured live `contextFill` stays near 0.41 while the trigger is 0.80. Everything else cascades from that.

1. `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift` — 4 issues, all downstream of the first:
   - `:296` `fillBeforeCompaction >= 0.80` → `fillBeforeCompaction` = **0.4130859375**
   - `:303` `fillAfterCompaction < fillBeforeCompaction` → fill *grew* to **0.427734375**, because `compact()` folded nothing and the compaction turn itself appended entries
   - `:315` `recall.contains("CRIMSON-77")` → the model answered `"I do not have access to the project brief or its vault code."` — the fact was never folded into a summary, so the post-compact turn cannot recall it
   - `:335` `checkpointedWindow.count < fullHistory.count` → 19 vs 19; with no fold there is no checkpoint boundary, so the restore view equals full history
2. `Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluationTests.swift:239` — `mean(CompactionContinuityMetric.foldOccurred) == 1.0` → **0.0**. Not one fold occurred in any sample. The assertion's own comment calls itself "the mechanical proof that held for this actual run, not merely an authoring-time claim" — it does not hold.
3. `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:199` — `mean(CompactionEvalMetric.factRetention) >= 0.9` → **0.0833…** (roughly 1 of 12 samples retained its fact).

## The contradiction to chase first

The hermetic tests that assert the fixtures are sized big enough all PASS in the same run:
- "every hand-written task is sized so its filler steps alone exceed the default budget's trigger threshold"
- "the default budget forces the model-assisted Summarization stage for every fixture, not just ToolOutputElision/TurnTruncation"

So the hermetic budget/trigger accounting and the live `contextFill` measurement disagree by roughly 2x. Either the hermetic sizing model mis-estimates token counts (e.g. assumes a smaller context window than the real 27B exposes, or counts characters/entries where the live path counts real tokens), or live `contextFill` reads a different denominator than the budget's trigger compares against. Find which side is wrong before touching any fixture size or threshold — resizing fixtures to brute-force the trigger would paper over a real accounting bug.

## Acceptance Criteria
- [ ] Root cause identified and stated: which of (hermetic sizing estimate) vs (live `contextFill` denominator) vs (trigger comparison) is wrong, with the token/window numbers that prove it
- [ ] The disagreement between the passing hermetic sizing tests and the measured 0.41 live fill is closed — they measure the same thing, or the hermetic test is corrected to stop asserting something untrue
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` reaches a real fold: `fillBeforeCompaction >= 0.80`, `foldOccurred` mean 1.0, `factRetention` mean >= 0.9
- [ ] `CompactionRoundTripIntegrationTests`' four assertions pass unmodified, or any change to them is justified as fixing a wrong assertion rather than lowering a bar
- [ ] Ungated `swift test` stays green

## Tests
- [ ] The gated run is the proof. Gated runs: one at a time, one shell command per run.
- [ ] Add ungated coverage pinning whichever accounting bug is found, so it cannot silently return
#phase-1