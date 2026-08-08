---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzgwp590yf3tte6jegt0jatt
  text: |-
    ### Research — root cause found, with numbers

    **Answer to "which side is wrong": the hermetic sizing estimate.** And a *second*, independent accounting bug in the trigger comparison. The live `contextFill` denominator is the only one of the three that is correct.

    #### Bug 1 — `Compactor.estimatedTokenCount(of:)` measures the JSON envelope, not the text

    `Compactor.payloadByteCount(of:)` does `JSONEncoder().encode(TranscriptEntryMapper.event(from: entry).payload)` and `estimatedTokenCount(bytes:)` then divides that by `charsPerTokenEstimate = 4.0` — a ratio whose own doc comment says it is "the commonly cited average for **English text** under BPE-style tokenizers". The bytes being divided are not English text. They are the on-disk `TranscriptEntryPayload` envelope: `entryId`, `contentRemoved`, every segment's `id` and `"type":"text"` discriminator, braces, quotes, commas, and `\n` → `\\n` escaping. None of that is ever sent to the model, so none of it is ever tokenized.

    Measured (throwaway diagnostic over a 5-entry transcript built from `CompactionRoundTripIntegrationTests.scriptedTurns`' first two turns):

    ```
    entries=5 contentChars=843 contentEstimate=210 payloadEstimate=369
    per-entry payload bytes: 154 (instructions, 27 content chars)
                             523 (prompt, ~400 content chars)
                             139 (response, 13 content chars)
    ```

    - **1.76x inflation** overall — the card's "roughly 2x".
    - A **fixed ~125 bytes (~31 phantom tokens) of envelope per entry**, independent of content. The fixtures use short ids (`prompt-1`, `prompt-1-text`); the SDK's real transcripts use UUIDs, making it ~180 bytes / ~45 phantom tokens per entry.

    The codebase already knows about this asymmetry: `Summarization.estimatedTokens(of text:)`'s doc says it applies the ratio "directly to a plain string's UTF-8 byte count **rather than a JSON-encoded payload**".

    This is why the two "sizing" tests pass while live fill says 0.41 — they are denominated in inflated envelope-tokens, and live `contextFill` is denominated in real tokenizer tokens.

    #### The 0.413 / 0.4277 numbers decode exactly

    - `fillBeforeCompaction = 0.4130859375` × 2048 = **846** — real tokenizer tokens from `LanguageModelSession.usage`, via `usageDelta`. Honest: the 8 scripted turns really are only ~846 tokens.
    - `fillAfterCompaction = 0.427734375` × 2048 = **876** — and 876 is `CompactionResult.tokensAfter`, written into `contextFill`'s numerator by `RoutedSession.fold`: `usageState = .measured(input: result.tokensAfter, output: 0)`.

    So the card's reading "`compact()` folded nothing" is **wrong**: the fold *did* run (assertions at :300/:301 are not in the failure list, so `stagesApplied` was non-empty and `tokensAfter < tokensBefore`). Fill grew because one writer of `contextFill`'s numerator uses real tokenizer counts and the other writes the inflated envelope estimate. Two units, one number.

    #### Bug 2 — the trigger compares two different denominators

    `RoutedSession.runTurn`: `if let budget = autoCompactionBudget, contextFill >= budget.trigger`.

    `contextFill` is `usageState.fill(contextTokens: contextTokens)` — a fraction of the *session's resolved working context*. `budget.trigger` is documented as a fraction of `budget.limit`. The comparison is only valid when `limit == contextTokens`.

    `CompactionContinuityEvaluation` deliberately passes `TokenBudget(limit: 2048, ...)` while its sessions resolve `CompactionEvalRealModel.context = 8192`. Intended trigger: 2048 × 0.80 = **1638** tokens. Actual trigger: 8192 × 0.80 = **6554** tokens — 4x too high. The tasks top out around ~1100 real tokens, so no fold can ever fire → `foldOccurred` mean exactly `0.0`. Same defect on the `hardCeiling` check.

    #### Third failure is downstream of bug 1

    `CompactionEvaluation` calls `Compactor.compact` directly (no trigger) with `TokenBudget(limit: 4000, target: 0.05)` → targetTokens 200 envelope-tokens ≈ **~110 real tokens**. The fold is forced ~1.8x harder than the design intends, which is the accounting reason the fold over-destroys content. (Any residual recall weakness after the accounting is fixed stays on `^pw807cp`; this card does not absorb it.)

    #### Fixtures really are undersized once the estimate is honest

    `compactionContinuityTaskSpecs` filler/setup steps are ~50-70 characters each; 14 steps ≈ 770 chars ≈ 190 real prompt tokens, plus ≤64 reply tokens each ≈ ~1100 real tokens total, against an intended 1638-token trigger. The hermetic sizing test asserts only `spec.fillerStepCount >= 8` — a step **count**, with no token accounting at all, while its name claims "sized so its filler steps alone exceed the default budget's trigger threshold". That assertion is untrue as written and must be replaced with a real token-size assertion.

    Plan: (1) make `estimatedTokenCount` count content-bearing text, not the JSON envelope; (2) express the trigger/hardCeiling checks in tokens against `budget.limit`; (3) replace the step-count sizing proxy with a real token-size assertion and size fixtures to satisfy it — in that order, so no fixture is resized to brute-force a trigger.
  timestamp: 2026-08-08T14:33:30.656754+00:00
- actor: claude-code
  id: 01kzgy0tpsfmfvypr46q9yq7jz
  text: |-
    ### Implementation landed; ungated green. Gated runs next.

    Ungated: `swift test` → **796 tests, 0 failures** (762 + 22 + 12 across the three targets). The only `warning:` line is SwiftPM's pre-existing `missing creator for mutated node ('…/mlx-swift_Cmlx.bundle/Contents/MacOS')`, a vendored-dependency resource-bundle build-graph warning, not a compiler diagnostic from this change.

    #### Production fixes

    1. **`Compactor.estimatedTokenCount(of: Transcript)` now measures content, not the JSON envelope.** `payloadByteCount(of:)` (JSON-encoded `TranscriptEntryPayload` size) is replaced by `contentByteCount(of:)` over a new `TranscriptEntryPayload.contentByteCount`, which sums only the fields that carry authored or model-visible content — segment content (all four `SegmentPayload` cases), tool definitions, tool calls, a `.toolOutput`'s tool name, asset ids, a reasoning signature's bytes, a response format's schema. `entryId`, segment/tool-call ids, `"type"` discriminators, `contentRemoved`, JSON punctuation and string escaping are all out; `options`/`responseFormatName` are out for the reason `strippingContent()` already documents.

    2. **The trigger and hard ceiling are compared in tokens against `budget.limit`.** New `TokenBudget.triggerTokens` / `targetTokens` / `ceilingTokens` / `fill(measuredTokens:)` (one shared rounding rule) and `ContextUsageState.measuredTokens`. `RoutedSession.runTurn` is now `measuredTokens >= budget.triggerTokens`, and the pre-flight ceiling check `measuredTokens >= budget.ceilingTokens`, instead of `contextFill >= budget.trigger` / `>= hardCeiling`. `contextFill` itself is unchanged — still a fraction of the session's resolved `contextTokens`, which `AutoCompactionTests` asserts deliberately. `Compactor` now reads `budget.targetTokens` rather than recomputing the same product. An unmeasured session (`measuredTokens == nil`) is left alone, matching the old `NaN >= trigger` behavior.

    #### A third bug fell out, and it blocked the fix

    `RoutedSession.loweredRetryTarget(from:)` was `max(target / 2, 0.1)` while its own doc comment says the result is "**strictly lower** than the budget's own configured target". It is not: for any target under `0.2` it returns something `>=` target, and under `0.1` it returns something strictly *greater*. A budget configured to fold to 5% of its limit had its reactive overflow-recovery retry fold to 10% — softer than the target that had already overflowed — so the retry was a guaranteed no-op and the overflow surfaced to the caller. Now `target / 2`, with no absolute floor: a floor stated as a fraction cannot be right when what counts as "meaningfully hard" depends on `limit`.

    This is not incidental. It is what made `AutoCompactionTests.hardCeilingFailsFastThenRecoversWithLivePerAttemptFill` fail once its budget's limit was corrected to match its session's context, and it is the same defect family as the card's: a threshold whose units and denominator do not line up with what it is compared against. Behavior is identical for every pre-existing in-repo target (all `0.25`/`0.35`/`0.9`).

    #### Test-side corrections

    - `AutoCompactionTests.fixedBudget` and `GuidedGenerationTests.autoCompactionFixedBudget` both set `limit: recencyOnly * 2` while their sessions resolved `context: 100_000`. That only "worked" because the trigger was compared against `contextFill`. Both now use `limit: <the session's own context>` with `target` expressed as the fraction landing on half the recency floor, so the trigger fires exactly where each suite's own `contextFill == 0.9` readings say it does, and `Summarization` is still forced. `hardCeilingBudget` is now built by overriding `fixedBudget` rather than restating its numbers.
    - `compactionEvalDefaultBudget` is a named constant, read by both `CompactionEvaluation.init` and the hermetic test that guards it (the test used to restate the literal, so the two could drift). `limit: 4000, target: 0.05` resolved to 200 tokens, **more than half of which was envelope padding**; with the padding gone every seed was already under target and `stagesApplied` came back `[]` for all 24 — the fold stopped happening entirely. Now `limit: 400, target: 0.10` → 40 tokens, below the smallest seed's recency-window floor of 63, so `Summarization` is forced again. That hermetic test earned its keep: it caught this immediately.

    #### Fixture sizing — the numbers, now that the accounting is honest

    Measured with the corrected estimator:

    | fixture set | was | trigger needs | now |
    |---|---|---|---|
    | `compactionContinuityFillerSteps` × 10-12 | 139-156 tokens | 1638 | 2475-2928 |
    | `CompactionRoundTripIntegrationTests.scriptedTurns` × 8 | 718 tokens | 1638 | 1834 |

    Both were ~11x and ~2.3x short. `compactionContinuityFillerSteps` is now six substantial paragraphs (still each closing with a one-word/one-sentence request, so replies stay short and the padding is all prompt-side, and none of them mentions any fixture's planted key phrases). The eight scripted turns are now ~900 characters each on the same weather-archive narrative, with `CRIMSON-77` still in the first.

    #### New ungated coverage (all watched failing first)

    - `CompactionTokenAccountingTests` — contentless entries estimate 0 (was 3 tokens/entry of envelope); the estimate ignores id length (UUID ids vs one-character ids); a text-only transcript agrees *exactly* with the single-string overload (was **139 vs 48**); and it still counts tool-call arguments, tool output, and asset ids, so the envelope fix did not narrow it to `.text` segments.
    - `CompactionContinuityEvaluationTests.everyTaskIsSizedToForceAFold` rewritten: it asserted `spec.fillerStepCount >= 8` — a step **count**, which says nothing about tokens, and which is how a dataset 11x too small shipped green under a test whose name claims "filler steps alone exceed the default budget's trigger threshold". It now measures the filler steps' estimated tokens against `compactionContinuityDefaultBudget.triggerTokens`. Watched failing at 139-156 vs 1638 on all ten fixtures.
    - `ScriptedTurnSizingTests` — a new **ungated** suite in the gated round-trip file (`context`/`scriptedTurns` moved `private` → `fileprivate` so it can read them). Two assertions: the turns carry more prompt tokens than the trigger needs, and the prefix that first crosses the trigger still fits the 2048-token window (so the crossing turn is never submitted with an unfittable prompt). Both watched failing when the turn list was temporarily cut to two entries: "estimate 489 prompt tokens, which does not exceed the trigger's 1638" and "no prefix of the scripted turns crosses the trigger at all".

    Next: the gated runs, one suite per shell command.
  timestamp: 2026-08-08T14:56:48.857065+00:00
- actor: claude-code
  id: 01kzh0e5heycf50nytpv9yyeqv
  text: |-
    ### Gated results — three runs, one suite per command

    #### 1. `CompactionRoundTripIntegrationTests` — GREEN, 61.8s

    ```
    ✔ Test "contextFill climbs, compact() folds at the 0.80 trigger preserving identity,
       a post-compact turn recalls the folded fact, restore yields the checkpointed
       window, and a further turn succeeds" passed after 61.795 seconds
    ✔ Test run with 3 tests in 2 suites passed
    ```

    All four assertions the card listed pass **unmodified**: `fillBeforeCompaction >= 0.80`, `fillAfterCompaction < fillBeforeCompaction`, `recall.contains("CRIMSON-77")`, `checkpointedWindow.count < fullHistory.count`. The third test in the run is the new ungated `ScriptedTurnSizingTests`.

    #### 2. `CompactionContinuityEvaluationIntegrationTests` — `foldOccurred` GREEN

    `mean(foldOccurred) == 1.0` **passes** in both gated runs. The instrumented run shows why, per sample:

    ```
    foldCount=1 before=2149 after=1380     foldCount=1 before=2104 after=1593
    foldCount=1 before=2138 after=1484     foldCount=1 before=2049 after=1531
    foldCount=2 before=2436 after=1965     foldCount=2 before=2293 after=2034
    foldCount=2 before=2426 after=1934     foldCount=1 before=2140 after=1522
    foldCount=1 before=2130 after=1609     foldCount=1 before=2138 after=1593
    ```

    Every one of the ten tasks folded, one or twice, at 2049-2436 tokens against the 1638-token trigger. That is the card's headline symptom — "Not one fold occurred in any sample" — closed.

    `answersCorrect >= 0.8` came back `0.5` on the first run and would have been `0.8` on the second (8 of 10 answers fully correct). It is flaky, not a fixed regression, and the two wrong answers name their own cause — see below. Note this assertion was **not** in the card's list of failures: with no fold ever happening, the model answered from an intact transcript, so it never had to survive a summary.

    #### 3. `CompactionEvaluationIntegrationTests` — `factRetention` still `0.0833`, and it is not an accounting failure

    Unchanged from the card's measurement. The instrumented run settles the cause: **every summary contains the planted fact verbatim.**

    ```
    summary=1. Intent — Inform the assistant of the internal codename for a new feature.
            2. Constraints & decisions — The internal codename for the new feature is "Project Longbow". …
    question=What is the internal codename for the new feature?
    answer=Noted.

    summary=… 2. Constraints & decisions — Staging database port is 6543. …
    question=What port does the staging database listen on?
    answer=Noted.

    summary=… The production deployment region is eu-west-2, selected for data-residency reasons. …
    question=Which region is the production deployment in, and why was it chosen?
    answer=Noted.
    ```

    The fold works. The summary carries the fact. The *answer* is `"Noted."` — the reply that belongs to acknowledging a fact statement in some earlier sample's conversation, not to this question. And where it is not `"Noted."` it is the summarizer's own output format:

    ```
    answer=1. Intent — The user is asking for specific information (return flight number)
           that was provided in the conversation.
    ```

    The two failing continuity samples show the identical signature, and both are `foldCount=2` samples — the ones that made an extra summarizer call:

    ```
    answer=1. Intent — The user asked for two specific pieces of information from the
           conversation history: the escalation time for a tier-1 ticket and the on-call
           escalation contact for the current week.
    answer=1. Intent — The user asked for the exact file paths to the migration script and
           its corresponding rollback script, without re-reading prior context.
    ```

    The other eight answered exactly right, folded facts included: `"The project's vault code is CRIMSON-77, and it is located at outpost Delta-9."`, `"The staging database listens on port 6543 and runs in the eu-west-2 region."`, `"Releases are cut from the \`release/stable\` branch, and they need sign-off from Priya before shipping."`

    This is the `^pw807cp` class, not this card's: a blank-slate summarizer session and the answering session share one resident container, so the summarizer's KV chunks bleed into the turn that follows it. It matches `^pw807cp`'s documented signatures ("narrating a call it never made", "the rebuilt session did not recall a fact its own transcript carried") and its run-to-run variability. Per this card's own scope note I have not absorbed that work; the evidence is filed on `^pw807cp`, whose AC asks for exactly this attribution.

    #### Acceptance criteria status

    - **Root cause identified and stated, with numbers** — done. The hermetic sizing estimate was wrong (JSON envelope counted as tokenizable text, 1.76x inflation, ~31-45 phantom tokens per entry); the live `contextFill` denominator was correct all along; and the trigger comparison was *also* wrong (a fraction of `contextTokens` compared against a fraction of `budget.limit`, 4x off for the continuity eval).
    - **The disagreement is closed** — the hermetic tests and the live measurement now count the same thing, and the sizing test that asserted an untrue claim (`fillerStepCount >= 8`) now measures tokens.
    - **A real fold is reached** — `fillBeforeCompaction >= 0.80` green; `foldOccurred` mean `1.0` green; `factRetention` remains `0.0833`, **attributed by direct evidence to `^pw807cp`** rather than to fill/trigger accounting. This is the one criterion this card cannot close inside its stated scope, and the card's own instruction is what keeps it out.
    - **The four round-trip assertions pass unmodified** — done, none changed.
    - **Ungated `swift test` stays green** — 796 tests, 0 failures.
  timestamp: 2026-08-08T15:39:03.086529+00:00
- actor: claude-code
  id: 01kzh0f9456zd5s5tn2cgem7ah
  text: |-
    ### implement — changed
    - evidence: 18 files. Sources: `Compaction/Compactor.swift`, `Compaction/TokenBudget.swift`, `Recording/TranscriptEntryPayload.swift`, `RoutedLLM.swift`, `Session/RoutedSession.swift`. Tests: `FoundationModelsRouterTests/CompactionTokenAccountingTests.swift` (new), `AutoCompactionTests.swift`, `GuidedGenerationTests.swift`; `FoundationModelsRouterEvals/CompactionContinuityDataset.swift`, `CompactionContinuityEvaluation.swift`, `CompactionContinuityEvaluationTests.swift`, `CompactionEvaluation.swift`, `CompactionEvaluationTests.swift`; `FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift`. Ungated `swift test`: 796 tests, 0 failures. Gated: `CompactionRoundTripIntegrationTests` green (all four listed assertions unmodified); `mean(foldOccurred) == 1.0` green; `mean(factRetention)` still `0.0833`, attributed by direct evidence to `^pw807cp`.
    - next: `/review`. One acceptance criterion (`factRetention` mean >= 0.9) is not closed and cannot be inside this card's stated scope — the summaries provably carry the planted fact verbatim and the *answers* are contaminated; evidence filed on `^pw807cp`.
  timestamp: 2026-08-08T15:39:39.525118+00:00
position_column: doing
position_ordinal: '80'
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