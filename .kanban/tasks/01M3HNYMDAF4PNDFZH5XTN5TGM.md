---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mjkn8fad2kyjb0g8p475py
  text: |-
    Research done.
    - `CompactionRoundTripIntegrationTests` and `Qwen38CompactionIntegrationTests` use `CompactionPrompt.default` through the session. They have no prompt parameter. To measure v8 on these two suites, the measurement run sets `default` to v8 in the local tree for that run only.
    - The continuity eval now names its prompt in `compactionContinuityEvalPrompt` (file scope in `CompactionContinuityRealModelTests.swift`). The `promptName` info also comes from it.
    - v7 and v8 share the first three lines and the last line. `CompactionPrompt.routerDefaultText(points:)` builds both texts, so the shared lines are not copied. The v7 text is unchanged (the v7 shape tests pass).
    - Machine: 128 GB memory; `mlx-community/Qwen3.8-27B-4bit`, `Qwen2.5-3B-Instruct-4bit` and `Qwen3-4B-4bit` are in the Hugging Face cache.
  timestamp: 2026-09-28T17:57:07.983998+00:00
- actor: claude-code
  id: 01m3mkk23zhd5c700pscts6jm0
  text: |-
    ### Gated measurement, v7 against v8 (2026-09-28, one machine: Apple silicon, 128 GB)
    Command (the same for both runs, from the repo root):
    `swift test --package-path IntegrationTests --filter 'CompactionContinuityEvaluationIntegrationTests|CompactionRoundTripIntegrationTests|Qwen38CompactionIntegrationTests'`
    Models: continuity eval and `Qwen38CompactionIntegrationTests` use `mlx-community/Qwen3.8-27B-mxfp4`; `CompactionRoundTripIntegrationTests` uses `mlx-community/Qwen2.5-3B-Instruct-4bit`.
    For the v8 run, `CompactionPrompt.default` was set to `routerDefaultV8` in the local tree for that run only. The continuity eval used `.default` in both runs, so each run measured one prompt in all three suites.

    | prompt | factsSurvived | answersCorrect | compactionOccurred | CompactionRoundTripIntegrationTests | Qwen38CompactionIntegrationTests |
    |---|---|---|---|---|---|
    | router-default-v7 | 1.0 | 1.0 | 1.0 | pass (11.8 s) | pass (130.4 s) |
    | router-default-v8 | 1.0 | 1.0 | 1.0 | pass (16.2 s) | pass (99.1 s) |

    Continuity suite wall clock: v7 282.0 s, v8 346.9 s. Each output names all three suites (4 tests in 2 suites, and 1 test in 1 suite).

    Decision (rule of this card): v8 is equal to v7 on both metrics, and neither metric is higher. v7 already has the maximum score (1.0) on the four fast tasks, so this eval cannot show an improvement for any prompt. `default` stays `router-default-v7`, and v8 is removed. The continuity eval keeps its named prompt (`compactionContinuityEvalPrompt`), so a later candidate can use the same procedure.
  timestamp: 2026-09-28T18:14:16.959447+00:00
- actor: claude-code
  id: 01m3mkket98vvjhg9pjex56btr
  text: |-
    ### implement — changed
    - evidence: 2 files — IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/CompactionContinuityRealModelTests.swift (the eval names its prompt in `compactionContinuityEvalPrompt`), Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift (doc comment records the v8 trial). v8 text and its shape test were written first (TDD: red, then 5 of 5 `CompactionPromptTests` green), used for the measurement, then removed by the decision rule (tie at 1.0 / 1.0).
    - next: /test
  timestamp: 2026-09-28T18:14:29.961500+00:00
position_column: doing
position_ordinal: '80'
title: Try compaction prompt router-default-v8 with the fact rules of Apple's SummarizeHistory, and keep it only when the gated evals show an improvement
---
## What

Write a test version of the default compaction prompt, `router-default-v8`, and measure it against `router-default-v7` on real models. Keep v8 as `CompactionPrompt.default` only when the measurements are better. If they are not better, keep v7 and record the numbers on this card.

Source of the idea: Apple's `foundation-models-utilities` package, file `Sources/FoundationModelsUtilities/History/SummarizeHistory.swift` (https://github.com/apple/foundation-models-utilities). Its default summarizer instructions ask for:
1. established facts — names, numbers, dates, decisions, preferences;
2. the current topic and what stage the conversation is at;
3. the thread most recently raised by the user;
4. any open questions or unresolved items;
and: "Use compact third-person statements … Do not narrate the conversation with phrases like 'the user said' or 'they discussed'. Compress aggressively but do not drop the active conversational thread."

Why: task ^pke18c2 recorded that, in the lost-fact seeds, "the summary lists the assistant's acknowledgements as the facts". The rules "third-person statements" and "do not narrate" address that failure.

v8 design (decided): keep the v7 structure. The `Values:` line stays FIRST (commit bbad3ce: a value line at the end was lost when the summary ran long). After it, replace the three v7 points with these rules:
- state each fact as a short third-person statement, not as a report of what someone said;
- give what the user wants now: the most recent thread the user raised;
- give what is decided, what must not be done, and what is still open.
Keep the last v7 line ("Leave out small talk …"). Do not add counting or length words (the v5 history in `CompactionPromptTests` shows why).

Files:
- `Sources/FoundationModelsRouter/Compaction/CompactionPrompt.swift` — add the v8 text. Until the measurement is done, keep `default` at v7 and add v8 as an `internal static let routerDefaultV8` so both can be measured in one run.
- `Tests/FoundationModelsRouterTests/CompactionPromptTests.swift` — the shape tests for v8.
- `IntegrationTests/Tests/FoundationModelsRouterEvalIntegrationTests/CompactionContinuityRealModelTests.swift` — let the continuity eval run with a prompt that the test names (the `CompactionContinuityEvaluation` in `Tests/FoundationModelsRouterEvalSupport/CompactionContinuityEvaluation.swift` already takes `prompt:`), so v7 and v8 run on the same machine.
- If v8 wins: set `CompactionPrompt.default` to v8, remove the `routerDefaultV8` name, and update the doc comment history in `CompactionPrompt.swift`.

## Acceptance Criteria
- [ ] The v8 text exists, starts with the same `Values:` line as v7, and has the three rules above.
- [ ] One gated run on one machine records, for v7 and for v8: `factsSurvived` and `answersCorrect` of `CompactionContinuityEvaluationIntegrationTests`, and pass or fail of `CompactionRoundTripIntegrationTests` and `Qwen38CompactionIntegrationTests`. The numbers are in a comment on this card.
- [ ] Decision rule: v8 becomes `CompactionPrompt.default` only when its `factsSurvived` and `answersCorrect` are each at least the v7 value, at least one of them is higher, and the two integration suites pass with v8. Otherwise `default` stays v7 and v8 is removed.
- [ ] `swift test` passes.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CompactionPromptTests.swift`: a test that v8 starts with the v7 `Values:` line, has each of the three rules, has no "Stated facts" section, and has the v7 last line.
- [ ] If v8 becomes the default: update `defaultPromptNameAndPoints` to expect `router-default-v8`.
- [ ] `swift test` — all pass.
- [ ] `swift test --package-path IntegrationTests --filter 'CompactionContinuityEvaluationIntegrationTests|CompactionRoundTripIntegrationTests|Qwen38CompactionIntegrationTests'` once with v7 and once with v8. Use type names in `--filter`: a display-name filter matches nothing and exits 0. Check that the output names each suite.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

#compaction