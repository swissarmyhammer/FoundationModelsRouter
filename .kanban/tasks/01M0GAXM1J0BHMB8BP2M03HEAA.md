---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0gj7awz26qnpntyk9strfbg
  text: |-
    Research done. Findings:
    - The model ref is one constant: `CompactionEvalRealModel.ref` in Tests/FoundationModelsRouterEvalSupport/CompactionEvalRealModel.swift. All hermetic tests read the constant (`CompactionEvalRealModel.ref.stringValue`), so no hermetic test pins the old name as a literal.
    - The subset tier runs under `compactionEvalSubsetTimeLimitMinutes` (1 minute). The whole-dataset tier runs under `compactionEvalFullDatasetTimeLimitMinutes` (3 minutes). The continuity suite runs the same model under `gatedEvalSuiteTimeLimitMinutes` (2 minutes) in GatedEvalSerialGate.swift.
    - `CompactionEvalTierBarTests` (Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift) holds the tier limits and the required sample counts against the constants in CompactionEvalTiers.swift.
    - Candidates in the HF cache: Qwen2.5-3B-Instruct-4bit (1.6 GB, no reasoning), Qwen3-1.7B-4bit (937 MB, reasons), Qwen3-4B-4bit, LFM2-1.2B, gemma-3-1b, granite-3.3-2b.

    Trial plan: swap the ref, raise the subset time limit for the trial so no time-limit abort can occur, run the 7-seed subset once for each candidate, and record counts and wall clock. First candidate: Qwen2.5-3B-Instruct-4bit (same family as the standard model, no reasoning, headroom 128 stays correct).
  timestamp: 2026-08-20T21:46:20.959455+00:00
- actor: claude-code
  id: 01m0gjb3fmpkw03webwc8nwb9a
  text: |-
    Trial 1 — `mlx-community/Qwen2.5-3B-Instruct-4bit`, 7-seed subset, greedy decoding, headroom 128, `router-default-v3` prompt with span-budget trim:

    | candidate | subset summaries | subset answers | dearest sample | model load | suite wall clock |
    |---|---|---|---|---|---|
    | Qwen2.5-3B-Instruct-4bit | 6 of 7 | 6 of 7 | 15.9 s | 1.2 s | 63.5 s |

    Per-sample costs (fold + answer, seconds): 5.4, 4.7, 12.2, 3.2, 5.1, 15.9, 15.9. Four of seven folds made one summarizer call; three made two. The one lost seed is `encryption-algorithm` (class=summaryLostFact, 2 summarizer calls).

    The candidate reaches the 5-of-7 target with margin, and the suite wall clock of 63.5 s is inside the two-minute budget. Per the method, this is the first candidate that wins, so the trial sequence stops here. Next: run the full 24-seed tier to set the whole-dataset baseline, with a raised time limit for the measurement so no time-limit abort can fire.
  timestamp: 2026-08-20T21:48:24.436085+00:00
- actor: claude-code
  id: 01m0gk7qqdym6438qsyz7bgses
  text: |-
    Whole-dataset run and continuity discovery.

    Full 24-seed tier under Qwen2.5-3B-Instruct-4bit: summaries 23 of 24, answers 23 of 24, wall clock 369.1 s, no seed unreached, model load 1.3 s. The one lost seed is `tabs-vs-spaces` class... correction: the lost seed is the one `summaryLostFact` row of the 24 (the report table shows 23 retained, 1 summaryLostFact). Late-run samples measured dearer than any subset sample (up to 82.4 s at sample 21), but the whole tier sits inside the bound the subset run's dearest sample derives (24 x 15.9 s + 1.3 s = 382.9 s).

    Discovery: the continuity tier (`CompactionContinuityEvaluationIntegrationTests`) resolves the same `CompactionEvalRealModel.ref`. Under Qwen2.5-3B it passes its floors but costs 219.1 s of wall clock — past task ^k0d30s4's two-minute budget that `gatedEvalSuiteTimeLimitMinutes = 2` states. Under the 1B it measured 26.2 to 41.4 s.

    Decision: the card orders a canary swap for the fact-retention tiers; the continuity tier is not on the card, and its floors (0.6 / 0.3) are the 1B's own measured baselines. So the continuity tier gets its own model constant and keeps `mlx-community/Llama-3.2-1B-Instruct-4bit`, the way each smoke suite already names its own model. This keeps every everyday integration test inside the two-minute budget and keeps each measured constant true to its own subject. `CompactionEvalRealModelContainer.load` gains `ref:`/`context:` parameters so the two runners name their own models. I will verify the continuity tier green under the 1B after the split.
  timestamp: 2026-08-20T22:04:02.669308+00:00
- actor: claude-code
  id: 01m0grvgqchkd29ty5t2ey3zad
  text: |-
    Resumed the card. The split that the last agent left in the working tree builds clean: `swift build --build-tests -Xswiftc -warnings-as-errors` at the root and in `IntegrationTests` both complete with no error and no warning. So no repair of the split was necessary.

    Arithmetic check of the derived limits, done again from the measured numbers:
    - Subset: 7 x 15.9 s + 1.3 s = 112.6 s = 1.877 min. The next whole minute above is 2.
    - Whole dataset: 24 x 15.9 s + 1.3 s = 382.9 s = 6.382 min. The next whole minute above is 7.
    `CompactionEvalTierBarTests` holds `limit >= derived` and `limit < max(derived, 1) + 1`; 2 and 7 satisfy both.

    Floor derivation, with the standing rule (the weaker tier's measured share minus one sample of that tier's margin):
    - Summaries: subset 6 of 7, one under is 5 of 7 = 0.7143. Whole dataset 23 of 24, one under is 22 of 24 = 0.9167. The subset is the weaker tier, so the floor comes from 5 of 7.
    - Answers: the same measurements on the answer side (subset 6 of 7, whole dataset 23 of 24), so the same derivation gives the same 5 of 7.
    - Written as 0.71. `CompactionEvalFactRetentionReport.share(of:over:)` is a plain division, so `compactionEvalFactRetentionRequiredSamples` gives 5 for 7 seeds (5/7 = 0.7143 clears, 4/7 = 0.5714 does not) and 18 for 24 seeds (18/24 = 0.75 clears, 17/24 = 0.7083 does not). The whole-dataset tier measured 23, so it clears 18 with five seeds to spare.

    Tokenizer measurement for `compactionEvalMeasuredBytesPerToken`. I first reproduced the corpus the doc names, in Swift, from `compactionEvalFixtureSpecs` (each `context` and each fact), `compactionEvalFactAcknowledgements`, `compactionEvalContextAcknowledgement`, and every `compactionEvalFillerTurns` prompt and reply: 85 pieces, 31541 UTF-8 bytes — the exact byte count the doc records. Encoding each piece on its own and summing then gives 6564 tokens under the Muse Glimmer tokenizer, the exact token count the doc records, which confirms the method. Over that same corpus:
    - Muse Glimmer 30B: 6564 tokens, 4.805 bytes for each token
    - Llama 3.2 1B: 6577 tokens, 4.796
    - Qwen2.5 3B: 6602 tokens, 4.777
    The Qwen2.5-3B rate is the SMALLEST of the three, so the constant keeps 4.81 (Muse Glimmer's 4.805, rounded up). The 4.524 the doc gave for the Llama tokenizer was taken over a different corpus (the single-line literals of the two dataset sources), so the table above re-states that tokenizer over the corpus this constant is really about.

    Discovery worth recording: the whole-dataset run measured samples DEARER than any subset sample — up to 82.4 s at sample 21 — and ended at 369.1 s against the 382.9 s the subset's dearest sample derives. That is 13.8 s of margin, 3.6 percent. The opt-in tier's bound is therefore much thinner than the subset's. I will file this as its own card.
  timestamp: 2026-08-20T23:42:13.740318+00:00
- actor: claude-code
  id: 01m0gvd8g8zfma6xs7dhmcmx06
  text: |-
    BLOCKER. The card's continuity decision rests on a premise that is false, and I cannot correct it inside this card.

    The decision recorded in the comment above says: "the continuity tier gets its own model constant and keeps `mlx-community/Llama-3.2-1B-Instruct-4bit` ... its floors (0.6 / 0.3) are the 1B's own measured baselines". The floors ARE the 1B's baselines, but they were measured on 2026-08-19, BEFORE task ^xx02yn6 redesigned the summarization prompt. Under the redesigned prompt the 1B no longer reaches them.

    Measured today, `swift test --package-path IntegrationTests --filter CompactionContinuityEvaluation`:

    ```
    factsSurvived   0.1  against compactionContinuityFastFactsSurvivedFloor  = 0.6
    answersCorrect  0.0  against compactionContinuityFastAnswersCorrectFloor = 0.3
    suite wall clock 92.8 s, against gatedEvalSuiteTimeLimitMinutes = 2 (120 s)
    ```

    I ran the tier twice to find whether the split caused this:
    - with my work in the tree: 0.1 and 0.0, 2 issues, 92.1 s
    - with the tree stashed back to `main` (`git stash push -u`, run, `git stash pop`): 0.1 and 0.0, the same 2 issues, 92.8 s

    So the failure is on `main` and the split did not cause it. That is expected: for the continuity tier the split changes only WHICH constant supplies the model reference and the context. Both constants hold the same values the tier had before — `mlx-community/Llama-3.2-1B-Instruct-4bit` and 8192 — so the tier's subject is unchanged.

    The conflict a person must settle: the 1B meets ^k0d30s4's two-minute budget and loses the facts (0.1 / 0.0); the Qwen2.5-3B keeps the facts and passes the floors, but costs 219.1 s, which is past that budget. No subject measured so far satisfies both. Lowering the floors to 0.1 and 0.0 would rebuild, on the continuity tier, the exact defect this card was opened to remove.

    I filed that as its own card: ^mx4jqrn. It records both runs, the cause, the three options, and the rule that the floors must not be lowered to the 1B's new numbers.

    I also filed ^de1yq0p for a second, unrelated red test the non-gated integration run showed: `turn2Usage.input.cachedTokenCount` is 0 in `LanguageModelSessionBackendTests`. I touch no file that reaches `MLXFoundationModelsSessionBackend`, so it is not this card's.

    And I filed ^5q0vv85 for the thin margin on the whole-dataset tier's derived bound.

    What I did NOT do, and why: I did not change the continuity floors, the continuity subject, or `gatedEvalSuiteTimeLimitMinutes`. Each of those is a measurement decision this card does not authorize, and each would make a standing constraint false.
  timestamp: 2026-08-21T00:26:52.296035+00:00
- actor: claude-code
  id: 01m0gvdp35h2qyn3mdqdkjtbze
  text: |-
    ### implement — stuck

    - files changed: 11 — `Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`, `Tests/FoundationModelsRouterEvalSupport/CompactionEvalRealModel.swift`, `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityRealModel.swift` (new), `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityEvaluation.swift`, `Tests/FoundationModelsRouterEvalSupport/CompactionEvalRecallInstructions.swift`, `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift`, and five files under `IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/`
    - final constants: `compactionEvalMeasuredDearestSampleSeconds = 15.9`, `compactionEvalMeasuredModelLoadSeconds = 1.3`, `compactionEvalSubsetTimeLimitMinutes = 2`, `compactionEvalFullDatasetTimeLimitMinutes = 7`, `compactionEvalSummaryFactRetentionFloor = 0.71`, `compactionEvalAnswerFactRetentionFloor = 0.71`, `compactionEvalMeasuredBytesPerToken = 4.81` (unchanged, and now measured), `compactionEvalReasoningTokenHeadroom = 128` (unchanged), `CompactionEvalRealModel.ref = mlx-community/Qwen2.5-3B-Instruct-4bit`, `CompactionContinuityRealModel.ref = mlx-community/Llama-3.2-1B-Instruct-4bit`
    - runs: `swift build --build-tests -Xswiftc -warnings-as-errors` green at the root and in `IntegrationTests`. Root `swift test`: 1025 tests in 96 suites passed (1 known issue), and 77 tests in 9 suites passed. Subset tier green: summary 6 of 7, answer 6 of 7, every one of the 7 seeds reached, 63.3 s suite wall clock, inside its 2-minute limit and inside ^k0d30s4's two-minute budget.
    - blocked by: `CompactionContinuityEvaluationIntegrationTests` measures 0.1 against a floor of 0.6 and 0.0 against a floor of 0.3. The comment above records both runs that prove the failure is on `main` and not from this card. Card ^mx4jqrn holds it.
    - also red, and not this card's: `LanguageModelSessionBackendTests` KV cache reuse, card ^de1yq0p.
    - next: a person settles ^mx4jqrn — the continuity tier's subject and floors — then this card's remaining item (a green continuity tier after the split) can close.
  timestamp: 2026-08-21T00:27:06.213143+00:00
position_column: doing
position_ordinal: '80'
title: Choose a fast eval canary model that the redesigned compaction prompt serves, and restore meaningful retention floors
---
Task ^xx02yn6 redesigned the summarization prompt and trim for Qwen3.8-27B (the standard model, thinking on). The redesign took Qwen from 0 of 7 to 5 of 7 stored subset summaries. The fast eval canary, `mlx-community/Llama-3.2-1B-Instruct-4bit`, moved the other way: 6 of 7 to 2 of 7 subset summaries, 17 of 24 to 13 of 24 whole-dataset summaries. The measured cause: the 1B ignores the stated size budget, generates to its ceiling, enumerates background head-first, and the last-resort cut drops the facts stated later in the span.

The retention floors follow the weaker tier's measured share minus one sample, so they fell to 0.14 on both sides (`Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`). A floor of 0.14 requires 1 of 7 subset seeds and 4 of 24 whole-dataset seeds. That is a weak regression signal: a change that breaks half of the retained seeds still passes.

## What to build

- Pick a small cached instruct model that follows a stated word budget better than the 1B, or accept the 1B and change what the canary asserts (for example, assert the RAW map answers carry the facts, before the condense and cut, so the canary measures the prompt and not the 1B's overshoot).
- Re-measure both tiers under the chosen canary, and re-derive the floors from the measurements with the standing rule. The floors must climb back to a level where one lost seed is visible.
- Keep the two-minute-budget property of the fast tier (task ^k0d30s4).
- Never disable thinking, never change the standard model, never gate by env var.

## Outcome

The canary is now `mlx-community/Qwen2.5-3B-Instruct-4bit`, the family the redesigned prompt is written for. Measured on 2026-08-20, greedy decoding, headroom 128, `router-default-v3` prompt with the span-budget trim:

| tier | summaries | answers | wall clock |
|---|---|---|---|
| subset, 7 seeds | 6 of 7 | 6 of 7 | 63.3 s |
| whole dataset, 24 seeds | 23 of 24 | 23 of 24 | 369.1 s |

Trial 1 won, so no other candidate was measured. The derived constants: dearest sample 15.9 s, model load 1.3 s, subset limit 2 minutes (7 x 15.9 + 1.3 = 112.6 s), whole-dataset limit 7 minutes (24 x 15.9 + 1.3 = 382.9 s). Both floors are 0.71, from the weaker tier (the subset) at 5 of 7 = 0.7143. That floor requires exactly 5 of 7 subset seeds and 18 of 24 whole-dataset seeds, so one lost seed is visible again. `compactionEvalMeasuredBytesPerToken` stays 4.81: the Qwen2.5-3B tokenizer measures 4.777 bytes for each token over the same corpus, which is the smallest of the three rates, and the rule keeps the largest.

The continuity tier was found RED on unmodified `main` during this work: `factsSurvived` 0.1 against a floor of 0.6, and `answersCorrect` 0.0 against 0.3. The same numbers came back with the working tree stashed, so this card did not cause it. The continuity tier gets its own model constant (`CompactionContinuityRealModel`, holding the 1B), so its subject can change alone. The decision is on card ^mx4jqrn, because no measured subject meets its floors and the two-minute budget together.

## Acceptance Criteria

- [x] The chosen canary's measured subset baseline is at least 5 of 7 stored summaries under the current `router-default-v3` prompt and span-budget trim
- [x] The floors are re-derived from the new measurements with the standing rule, and `CompactionEvalTierBarTests` holds the new required counts
- [x] The subset tier stays inside the fast budget
#compaction #eval #real-model