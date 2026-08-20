---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Choose a fast eval canary model that the redesigned compaction prompt serves, and restore meaningful retention floors
---
Task ^xx02yn6 redesigned the summarization prompt and trim for Qwen3.8-27B (the standard model, thinking on). The redesign took Qwen from 0 of 7 to 5 of 7 stored subset summaries. The fast eval canary, `mlx-community/Llama-3.2-1B-Instruct-4bit`, moved the other way: 6 of 7 to 2 of 7 subset summaries, 17 of 24 to 13 of 24 whole-dataset summaries. The measured cause: the 1B ignores the stated size budget, generates to its ceiling, enumerates background head-first, and the last-resort cut drops the facts stated later in the span.

The retention floors follow the weaker tier's measured share minus one sample, so they fell to 0.14 on both sides (`Tests/FoundationModelsRouterEvalSupport/CompactionEvalTiers.swift`). A floor of 0.14 requires 1 of 7 subset seeds and 4 of 24 whole-dataset seeds. That is a weak regression signal: a change that breaks half of the retained seeds still passes.

## What to build

- Pick a small cached instruct model that follows a stated word budget better than the 1B, or accept the 1B and change what the canary asserts (for example, assert the RAW map answers carry the facts, before the condense and cut, so the canary measures the prompt and not the 1B's overshoot).
- Re-measure both tiers under the chosen canary, and re-derive the floors from the measurements with the standing rule. The floors must climb back to a level where one lost seed is visible.
- Keep the two-minute-budget property of the fast tier (task ^k0d30s4).
- Never disable thinking, never change the standard model, never gate by env var.

## Acceptance Criteria

- [ ] The chosen canary's measured subset baseline is at least 5 of 7 stored summaries under the current `router-default-v3` prompt and span-budget trim
- [ ] The floors are re-derived from the new measurements with the standing rule, and `CompactionEvalTierBarTests` holds the new required counts
- [ ] The subset tier stays inside the fast budget

#compaction #eval #real-model