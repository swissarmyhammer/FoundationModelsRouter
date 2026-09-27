---
assignees:
- claude-code
position_column: todo
position_ordinal: a680
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