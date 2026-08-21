---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0jqt8cmgrtzq2m868k2wxfp
  text: |-
    ## Decision, 2026-08-21 (orchestrator)

    The second assertion compares `cachedTokenCount` against turn 1's prompt, `turn1Usage.input.totalTokenCount`, as the LOWER bound, and against turn 1's prompt plus response as the UPPER bound:

    - `cachedTokenCount >= turn1Usage.input.totalTokenCount` — the prompt of turn 1 is the prefix the ledger can serve for every model. `TranscriptConverter` drops prior-turn reasoning on purpose, so for a reasoning model the response can not come back as input, and no assertion may demand it.
    - `cachedTokenCount <= turn1 input + turn1 output` — turn 2 can not reuse more than turn 1 processed.
    - `cachedTokenCount > 0` stays.

    Why this is not a weakening: the old reference (prompt plus response) rested on a premise that is false for a reasoning model whose reasoning is not replayed. The new bounds still fail on 0, on a partial prompt reuse, and on an over-report. The measured 50 against a 49-token prompt sits inside the bounds with no tolerance needed; the `max(8, processed / 4)` tolerance goes away with the approximate-equality it served.

    The work lands on ^de1yq0p (the assertion, the test name, the doc comment, the card text). This card closes when that suite is green.
  timestamp: 2026-08-21T18:02:32.724618+00:00
- actor: claude-code
  id: 01m0jrdd4da6m57zpav2t1g7cg
  text: |-
    Implemented on ^de1yq0p, 2026-08-21. The change is in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, test `secondTurnReusesFirstTurnsKVCache`:

    - `cachedTokenCount > 0` stays.
    - The approximate equality against turn 1's prompt plus response, and its `max(8, processed / 4)` tolerance, are gone.
    - Two bounds replace them: `turn2Usage.input.cachedTokenCount >= turn1Usage.input.totalTokenCount` (turn 1's prompt is the prefix the ledger can serve for every model) and `turn2Usage.input.cachedTokenCount <= turn1Usage.input.totalTokenCount + turn1Usage.output.totalTokenCount` (turn 2 can not reuse more than turn 1 processed).
    - The display string now reads "turn 2's usage.input.cachedTokenCount is positive, covers turn 1's whole prompt, and does not exceed everything turn 1 processed — the KV cache is reused, not recomputed". The comment above the bounds states the reasoning-channel divergence, the measured counts of 2026-08-21 (turn1In=49 turn1Out=84 turn2Cached=50 at fork pin 41e9f41), and points at this card.
    - `plan.md` no longer says the second assertion is red; it states the two bounds and points at this card.

    Suite run `swift test --package-path IntegrationTests --filter LanguageModelSessionBackendIntegrationTests`: 11 tests in 1 suite passed after 347.5 s (362 s wall clock of the call). The test printed `turn1In=49 turn1Out=93 turn2Cached=50`; 50 sits inside [49, 142] with no tolerance. Root `swift test`: 1032 tests in 98 suites passed (2 pre-existing known issues) plus 77 tests in 9 suites passed. All three boxes are ticked: the second one on the suite result measured above.
  timestamp: 2026-08-21T18:13:00.173494+00:00
- actor: claude-code
  id: 01m0jrrp8hs2m8bscsnwyvh0ng
  text: Closed by the orchestrator on 2026-08-21. The decision is recorded above, the bounds landed in commit bdbe7aa under ^de1yq0p, the suite measured green (11 tests, 347.5 s), and the review of bdbe7aa was clean. All three acceptance boxes are ticked.
  timestamp: 2026-08-21T18:19:09.969449+00:00
position_column: done
position_ordinal: ffe480
title: Decide what secondTurnReusesFirstTurnsKVCache's second assertion must compare against for a reasoning model
---
Card ^de1yq0p moved the `mlx-swift-lm` pin to `41e9f41` (both packages). The fork now accepts the batched, masked text-only input that `MuseGlimmerProcessor` renders, and the first assertion of `secondTurnReusesFirstTurnsKVCache` (`cachedTokenCount > 0`) is green. The second assertion stays red.

Measured 2026-08-21, `swift test --package-path IntegrationTests --filter secondTurnReusesFirstTurnsKVCache`:

```
[secondTurnReusesFirstTurnsKVCache] turn1In=49 turn1Out=84 turn2Cached=50
cachedTokenCount (50) should approximate turn 1's total processed tokens (133) within 33
```

The full suite run gave `cachedTokenCount` 50 against 197 processed (tolerance 49).

## Why the count is the prompt of turn 1 and no more

- The fork's cache ledger holds the render of turn 1 plus every token turn 1 generated (`ExecutorPromptCachePlan.committed(generatedTokens:)`).
- `TranscriptConverter.mlxMessages(for:)` drops `.reasoning` entries on purpose: "Prior-turn reasoning is intentionally NOT replayed into the model's chat history."
- Muse Glimmer reasons in a `to=self` channel. Turn 1 generates ` to=self<|message|>...<|eom|><|start|>assistant<|message|>OK<|eot|>` after the generation prompt `<|start|>assistant`. Turn 2 renders the assistant entry as `<|start|>assistant<|message|>OK<|eot|>`. The two diverge at the first generated token, so `reusablePromptPrefix` rewinds the cache to the end of turn 1's prompt: 49 tokens, plus one.

So for a reasoning model whose reasoning is not replayed, turn 2 can reuse the prompt of turn 1 and nothing of its response. The assertion's premise — "every token turn 1 processed, its prompt plus its own generated response, becomes part of the transcript turn 2 sends" — does not hold.

## What to decide

- What the second assertion must compare `cachedTokenCount` against. The candidates: turn 1's `input.totalTokenCount` (the prefix the ledger can serve), or the prompt plus the visible response when the model reasons in no separate channel.
- Whether the tolerance `max(8, processed / 4)` still fits the chosen reference.
- Card ^de1yq0p was forbidden to weaken or change that assertion; this card owns the decision. Do not change `RealModels.standard` to dodge it.

## Acceptance Criteria

- [x] The second assertion names the reference it compares against and why, in one comment
- [x] `swift test --package-path IntegrationTests --filter LanguageModelSessionBackendIntegrationTests` is green
- [x] The assertion still requires a positive `cachedTokenCount` and still compares it against a measured count of turn 1 #integration #real-model