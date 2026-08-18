---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0ad11qhfcv8b35wp9vekafy
  text: |-
    Picked up. Research done, before any edit.

    ## The cached models on this box

    `~/.cache/huggingface/hub` holds 47 repositories. The small real instruct models present, by size on disk:

    | repository | size |
    |---|---|
    | `mlx-community/SmolLM-135M-Instruct-4bit` | 75 MB |
    | `mlx-community/LFM2-1.2B-4bit` | 633 MB |
    | `mlx-community/Llama-3.2-1B-Instruct-4bit` | 680 MB |
    | `mlx-community/gemma-3-1b-it-qat-4bit` | ~700 MB |
    | `mlx-community/Qwen3-1.7B-4bit` | 937 MB |
    | `mlx-community/granite-3.3-2b-instruct-4bit` | 1.3 GB |
    | `mlx-community/Qwen2.5-3B-Instruct-4bit` | 1.6 GB |

    Nothing needs downloading. `Llama-3.2-1B-Instruct-4bit` is the pick: a real instruct model, complete snapshot on disk, and it writes NO `<think>` block — which is the whole reason `Muse-Glimmer-30B-4bit` needs a 4096-token reasoning headroom. `Qwen3-1.7B-4bit` is rejected because it reasons.

    `Muse-Glimmer-30B-4bit` is what `RealModels` and `CompactionEvalRealModel` both name, and it is 18 GB. It is not used here.

    ## Where the gate goes

    The repository has exactly two environment gates, and both use one shape: a file-private `let` naming the variable, a file-private computed `var` doing a `!= nil` lookup, and a SUITE-level `.enabled(if:)` trait. No `@Test` carries `.enabled(if:)`.

    - `FM_ROUTER_INTEGRATION_TESTS` — read in 12 files, each re-declaring its own file-private constant because Swift `private` at top level is file-scoped.
    - `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` — read beside it in `CompactionEvaluationTests.swift`, composed with `&&` and `&& !` to make the two eval tiers exclusive.

    So the new gate is a third variable read the same way, in its own file, with its own suite trait. Nothing else changes.

    ## What the fold arithmetic actually measures

    `Compactor.estimatedTokenCount(of:)` sums the UTF-8 CONTENT bytes of each entry and divides by `charsPerTokenEstimate = 4.0`, rounding up. `contentByteCount` keeps entry ids, segment ids, `"type"` discriminators and JSON punctuation OUT of the sum.

    The did-not-shrink guard is `if tokensAfter < tokensBefore` in `Compactor.compact`. When it does not hold, the function falls through to `shortfallResult` — `stagesApplied: []`, `summary: nil`, `tokensAfter == tokensBefore` — and returns the ORIGINAL transcript. That is the exit `^fm5ddk9` hit on 7 of 7 seeds.

    `Summarization` output ceiling is `summaryTokenAllowance(condensing:) + reasoningTokenHeadroom`, where the allowance is `min(maximumSummaryTokens, max(128, ceil(spanTokens * 0.25)))` and `maximumSummaryTokens` is what a full `maxChunkTokens = 2000` earns, so 500. `reasoningTokenHeadroom` defaults to 4096 and is a public initializer knob — a non-reasoning model needs almost none of it.

    `^fm5ddk9` measured the real 30B model writing summaries of 450 to 840 estimated tokens against spans of 345 to 444 estimated tokens — 1.30x to 2.07x. The fix for a smoke test is a span far larger than any summary the model can write under its own character directive, not a change to the directive.

    ## The plan

    - Fixture: one seed, one chunk. Span sized so a single summarizer call covers it (under `maxChunkTokens`) and so the summary cannot fail to shrink it.
    - One generation: `Compactor.compact` only. No resumed session and no answering turn.
    - `reasoningTokenHeadroom` cut down for a model that writes no reasoning, which bounds the worst-case generation.
    - The suite reuses `MetalLibraryTestBootstrap` through the target's existing `.exclusiveRealModel` trait rather than reading the bootstrap directly.
  timestamp: 2026-08-18T12:20:05.489660+00:00
- actor: claude-code
  id: 01m0adtq29hf06z6yqdnpmzpsm
  text: |-
    Implementation landed, measured, and green. What follows is the record a later reader needs.

    ## The red step, and what it proved

    The test was driven RED before it was driven green, on purpose, because a smoke test that passes on its first run has proved nothing about its own assertions.

    The red was made by reversing the fixture order so the folded span became the two SHORT prompts instead of the two long ones — one token of change, and the same condition `^fm5ddk9` reported. The run printed:

    ```
    summarizerCalls=1 ceilings=[256] spanTokens=33 summaryTokens=0 tokensBefore=670 tokensAfter=670 stages=[]
    ✘ Expectation failed: result.summary
    ```

    That is `Compactor.compact`'s shortfall exit, word for word: the summarizer RAN, it answered, and the fold was thrown away because it did not shrink. `tokensAfter == tokensBefore`, `stages=[]`, `summary` nil. The assertions are load-bearing.

    The fixture order was then restored, and the same run went green.

    ## The green run

    ```
    summarizerCalls=1 ceilings=[281] spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374 stages=["ToolOutputElision", "TurnTruncation", "Summarization"]
    wallClockSeconds=4.1 modelLoadSeconds=2.0
    ```

    All five facts the card asks for: one summarizer call, a summary of 304 estimated tokens against the 600-token span it replaced, `stagesApplied` ending in `Summarization`, and 670 tokens folded down to 374.

    ## The measurement

    Five runs of the test, and every one reported byte-identical fold numbers — which is `samplingMode: .greedy` doing its job, so a red run here is attributable to the change under test rather than to a sampled reply.

    | what was measured | figure |
    |---|---|
    | the test's own wall clock | 4.0 s to 4.3 s |
    | of which the model load | 1.9 s to 2.0 s |
    | `swift test --filter CompactionSmokeIntegrationTests` end to end | 10.2 s to 16.3 s |
    | `swift test` with NO filter, smoke gate set | 18.0 s |

    The 90-second budget is met with a factor of about 20 to spare on the test itself.

    The last row is the acceptance criterion about the gate, measured rather than argued: with `FM_ROUTER_COMPACTION_SMOKE=1` and no filter, the WHOLE package ran in 18.0 seconds — 978 unit tests, 28 in the integration target, 58 evals — this suite's real model included, and not one `FM_ROUTER_INTEGRATION_TESTS` suite ran.

    ## Why the fold is certain rather than lucky

    `^fm5ddk9`'s defect was a real model writing a summary LARGER than the span it replaced, 1.30x to 2.07x, on 7 of 7 seeds. That cannot happen here, and the reason is arithmetic rather than model behaviour.

    `Summarization`'s output ceiling is a HARD STOP on the whole generation, and it is `summaryAllowance + reasoningTokenHeadroom`. The suite sets the headroom to 128 rather than the default 4096, because the smoke model writes no `<think>` block. So the largest summary the fold can possibly be handed is bounded by the ceiling, whatever the model does.

    Measured: the 600-token span bought a ceiling of 281, and the model wrote to it — 304 estimated tokens, a little over half the span. The margin is the ceiling's, not the model's restraint. The fixture is sized so that bound sits under the span, and the budget is DERIVED from the fixture rather than written beside it, so a fixture that changes size carries its own budget with it.

    ## Decisions worth knowing

    - **The model is named locally, not added to `RealModels`.** `RealModels` is the target's roster of the three profile SLOTS, and a smoke model is not a slot. `CompactionEvalRealModel` in the evals target is the prevailing pattern for "a suite that needs its own model at its own context", and this follows it. `RealModels` is untouched.
    - **`Qwen3-1.7B-4bit` was rejected** although it is a comparable size: it reasons, which is the exact property that made the 4096-token headroom necessary in the first place.
    - **Nothing was downloaded.** Every candidate was already in the Hugging Face cache.
    - **The length directive in `Summarization` was not changed**, and no existing assertion was weakened. The only production knob touched is `reasoningTokenHeadroom`, through its own public initializer parameter, at this suite's call site.

    ## Something a reviewer should not attribute to this card

    The working tree carries uncommitted changes to five files under `Tests/FoundationModelsRouterEvals/` and to two other kanban cards. Those are ANOTHER session working this repository at the same time. This card touched exactly one source file.
  timestamp: 2026-08-18T12:34:06.537613+00:00
- actor: claude-code
  id: 01m0advwgnpha9saynr848qs6x
  text: |-
    ### implement — changed
    - evidence: 1 file — /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterIntegrationTests/CompactionSmokeIntegrationTests.swift (new). `swift build` clean; `swift build --build-tests -Xswiftc -warnings-as-errors` zero diagnostics; `swift test` 978 + 28 + 58 pass with the one pre-existing `BoundedWait` known issue. Gated run `FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests`: passed in 4.1 s wall clock, 1.9 s of it the model load — `summarizerCalls=1 spanTokens=600 summaryTokens=304 tokensBefore=670 tokensAfter=374 stages=["ToolOutputElision", "TurnTruncation", "Summarization"]`. Red step first: the same test with the fixture order reversed reported `spanTokens=33 tokensBefore=670 tokensAfter=670 stages=[]` and failed on the nil summary, which is `^fm5ddk9`'s shortfall exit.
    - next: ready for /review. 12 of 12 acceptance criteria checked. Nothing open.
  timestamp: 2026-08-18T12:34:44.885634+00:00
position_column: doing
position_ordinal: '8180'
title: A compaction smoke test that answers "does compaction work at all" against a real model in under 90 seconds
---
Every present way to ask whether compaction works costs 28 minutes and gives back one bit. A run on 2026-08-17 burned 1800 seconds and measured 0 of 7 seeds. `^bgxtdk3`, `^vjf3mdm` and `^fm5ddk9` each waited a full gated run to learn a fact a fast test could have stated in a minute.

There must be a way to ask "does the compaction path work end to end against a real model" that finishes in less than 90 seconds of wall clock, model load included.

## Scope

The test proves the path WORKS. It does NOT prove fact retention quality — that stays with the slow eval tier. The test's own doc comment must say so, so nobody mistakes its scope later.

## What it proves

- The summarizer was called.
- The summarizer answered with text that is not empty (`^bgxtdk3` stored an empty summary on 19 of 19 seeds).
- The summary is smaller than the span it replaces, in the same unit `Compactor`'s did-not-shrink guard measures (`^vjf3mdm`, `^fm5ddk9`).
- The fold was APPLIED: `stagesApplied` ends with `Summarization.stageName`, not the shortfall exit.
- `tokensAfter < tokensBefore` on the returned result.

## How it stays under 90 seconds

- Do NOT load `mlx-community/Muse-Glimmer-30B-4bit`. 18 GB of weights eats the whole budget. Use the smallest real model already in the Hugging Face cache on this box.
- ONE seed, not seven. The smallest fixture whose span still clears the fold arithmetic.
- ONE generation. The fold only. No resumed session and no answering turn — that is a second generation and "works at all" does not need it.
- An output ceiling sized for this test, not the one inherited from the 30B path.

## Acceptance Criteria

- [x] The test has its own environment-variable gate, separate from `FM_ROUTER_INTEGRATION_TESTS`, so it runs without dragging in the 28-minute tiers. It follows the gate pattern the repository already uses; it does not invent a second mechanism. — `FM_ROUTER_COMPACTION_SMOKE`, read as a file-scoped constant with a `!= nil` lookup and a suite `.enabled(if:)` trait. Measured: with that variable set and NO filter, the whole `swift test` ran in 18.0 s and no `FM_ROUTER_INTEGRATION_TESTS` suite ran.
- [x] The test loads a small real model already present in the Hugging Face cache, not `Muse-Glimmer-30B-4bit`. — `mlx-community/Llama-3.2-1B-Instruct-4bit`, 680 MB, already cached. Nothing downloaded.
- [x] The test asserts the summarizer was called. — `ceilings.count == 1`, which also pins the one-generation budget.
- [x] The test asserts the summary text is not empty.
- [x] The test asserts the summary is smaller than the span it replaces, in the unit the did-not-shrink guard measures. — 304 estimated tokens against a 600-token span.
- [x] The test asserts `stagesApplied.last == Summarization.stageName`.
- [x] The test asserts `tokensAfter < tokensBefore`. — 374 against 670.
- [x] The test prints its own wall-clock duration, and the model load time as a separate number. — `[compactionSmoke] wallClockSeconds=... modelLoadSeconds=...`, from a `defer` so a red run states it too.
- [x] A measured run comes in under 90 seconds. The report states the observed figure, not an estimate. — 4.0 s to 4.3 s over five runs, of which 1.9 s to 2.0 s is the model load.
- [x] A `.timeLimit` trait bounds the test a little above the measured figure, and the constant behind it states its measurement the way `GatedRealModelBudget` states its own. — `compactionSmokeTimeLimitMinutes = 1`, the smallest `.timeLimit` Swift Testing accepts; the suite doc carries the three-run table behind it.
- [x] The doc comment says the test proves the path works and does not measure fact retention.
- [x] `swift build`, `swift build --build-tests -Xswiftc -warnings-as-errors` and `swift test` are clean: zero failures, zero warnings, one expected pre-existing `withKnownIssue`. — 978 + 28 + 58 tests pass, one known issue at `BoundedWait.swift`.

## Constraints

- Never run `swift format` or `swiftformat` in this repository.
- No `@MainActor` on tests in this target.
- Keep Swift-idiomatic acronym casing (RAM/JSON/LLM).
- Do not weaken any present assertion, and do not change the length directive in `Summarization`.
- Do not run `FM_ROUTER_INTEGRATION_TESTS=1` or `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` while working this card.

## How to run it

```
FM_ROUTER_COMPACTION_SMOKE=1 swift test --filter CompactionSmokeIntegrationTests
```
#compaction #real-model #eval