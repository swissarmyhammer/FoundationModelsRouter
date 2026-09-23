---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m35rh7n83dkd1cajw1cwayny
  text: |-
    ### Blocker: the 27B needs a source change before a compaction can run

    **What I changed (uncommitted, in the working tree):**
    - `Tests/FoundationModelsRouterEvalSupport/CompactionEvalRealModel.swift`: `ref` is `mlx-community/Qwen3.8-27B-mxfp4`. The doc comment states the owner's decision and keeps the 3B text as history.
    - `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityRealModel.swift`: the same.
    - `context = 8192` is not changed. No floor, no prompt and no file under `Sources/` is changed.

    **Command:** `swift test --package-path IntegrationTests --filter FoundationModelsRouterEvalIntegrationTests` (41.3 s real).

    **Output:**
    - The model loads: `model load returned ref=mlx-community/Qwen3.8-27B-mxfp4 took=2.6s` (continuity: 2.2 s).
    - Fact retention: `0 of 7 seeds measured`, `unreached: 7 of 7 seeds never ran`. Suite wall clock 2.8 s.
    - Continuity: `continuity measured tasks=4 compactionOccurred=-1.0 factsSurvived=-1.0 answersCorrect=-1.0`. Suite wall clock 25.3 s. Step 1 of each task answered (5.4 to 6.2 s). Step 2, which compacts, failed.
    - The `.xcevalresult` attachments (`--attachments-path`) hold one error for each sample, 7 of 7 and 4 of 4: `SubjectInferenceError: The operation couldn't be completed. (Jinja.TemplateException error 1.)`.

    **Cause:** The Qwen3.8-27B chat template (`chat_template.jinja:88-101`) raises `No user query found in messages.` when the message list holds no user message. A render of the template with jinja2 shows it: system only -> raises; system + assistant -> raises; system + user -> OK. `Summarization.plan` counts sub-transcripts that hold no user message through `TokenizerTokenCounter.count(_ transcript:)`, which renders the chat template:
    - `Sources/FoundationModelsRouter/Compaction/Summarization.swift:98` counts the instructions entry alone (a system message only).
    - `:83` counts the protected tool outputs alone, and `:346` counts the snapshot entries.
    The error thus comes before the summarizer call. It is the same class of fault as ^9ax82gr (the Llama template: "Cannot put tools in the first user message when there's no first user message!").

    **Real-model results:** fact retention summaries 0/7, answers 0/7 (no seed ran); continuity 0/4 (no task compacted). These are not measurements of the summarizer. No lost-seed example exists, because no summary was written.

    **Unit suite:** `swift test`: 1298 tests in 145 suites passed (2 known issues, not new), 1 test passed, 83 eval tests passed. `IntegrationTests` builds.

    **The one question for the owner:** The fix is a change under `Sources/` (the token count of an entry set with no user message, in `TokenizerTokenCounter` or in `Summarization.plan`), and this card forbids a source change. Do you want ^9ax82gr (or a new card) to correct the count for templates that need a user message, before this card runs the tiers again?
  timestamp: 2026-09-22T23:52:03.496895+00:00
- actor: claude-code
  id: 01m35rhbv4k6bx5sxn1kdfzj1g
  text: |-
    ### implement — stuck
    - evidence: 2 files changed, not committed: Tests/FoundationModelsRouterEvalSupport/CompactionEvalRealModel.swift, Tests/FoundationModelsRouterEvalSupport/CompactionContinuityRealModel.swift. Both tiers load the 27B, but every sample fails with `Jinja.TemplateException` ("No user query found in messages.") before the summarizer call. The fix is under `Sources/`, which this card forbids. See the blocker comment above.
    - next: the owner decides on the source change (^9ax82gr or a new card). Then run the tiers again.
  timestamp: 2026-09-22T23:52:07.780624+00:00
- actor: claude-code
  id: 01m35rhn73e3p9k31z61e8bjr8
  text: |-
    ### finish iteration 1 — implement: stuck
    - implement: stuck — both `ref` constants name `mlx-community/Qwen3.8-27B-mxfp4` (uncommitted); every sample fails with `Jinja.TemplateException` ("No user query found in messages.") from the token count of entry sets with no user message (`Summarization.swift:98`, `:83`, `:346` through `TokenizerTokenCounter.count(_ transcript:)`); the fix is under `Sources/`, which the card forbids
    - test: green — `swift test`: 1298 tests in 145 suites (2 known issues, not new), 1 test, 83 eval tests: all pass; `IntegrationTests` builds
    - real-model (Qwen3.8-27B): fact retention summaries 0/7, answers 0/7 (0 of 7 seeds ran); continuity 0/4 (metrics -1.0, 4 of 4 inference failures); run time 41.3 s for both suites (fact retention 2.8 s, continuity 25.3 s, model load 2.6 s and 2.2 s)
    - commit: no-change
    - review: not run — the task stays in doing for the owner's decision
  timestamp: 2026-09-22T23:52:17.379601+00:00
depends_on:
- 01M35GXDMSN5FPXVKZT9AX82GR
position_column: doing
position_ordinal: '80'
title: 'Run the compaction eval tiers on the model we ship: Qwen3.8-27B'
---
## Decision (from the owner, 2026-09-22)

The gated compaction eval tiers measure the summarizer on `mlx-community/Qwen2.5-3B-Instruct-4bit`. The product runs `mlx-community/Qwen3.8-27B-mxfp4`. The owner chose: both tiers run on the 27B from now on.

## Sites

- `Tests/FoundationModelsRouterEvalSupport/CompactionEvalRealModel.swift:52` `ref` (fact retention).
- `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityRealModel.swift:52` `ref` (continuity).
- The `context = 8192` constants (`:66`, `:60`) stay: they are the eval session's window, a test number the planted transcripts are sized to.
- Docs and comments that name Qwen2.5-3B as the eval model (search `Qwen2.5-3B` in `Tests/`, `IntegrationTests/`, docs).

## Do this

1. Change both `ref` constants to `mlx-community/Qwen3.8-27B-mxfp4`. The model is in the local cache; the machine has 512 GiB.
2. Update the docs and comments that name the old eval model.
3. Run the fact-retention tier and the continuity tier. Record on this card: summaries k/7, answers k/7 (floor 5/7), continuity k/4, lost seeds with one example each, and the run time.
4. Do not change a floor, the compaction prompt, or any source file. If the 27B needs a change to load (a chat template, a reasoning-block parse), record it on the card and report it; do not add a limit.

## Acceptance

- Both tiers run on the 27B.
- The results are on the card.
- All unit tests pass; `IntegrationTests` builds. #compaction