---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: plan.md and the KV-cache test comment state a stale reason for the red cachedTokenCount test
---
Found while task ^de1yq0p looked for the cause of the red `secondTurnReusesFirstTurnsKVCache`. Two places in this repository state a reason that the pinned fork revision refutes. Both send the next reader down a dead end.

## What is stale

1. `plan.md`, section "Sessions & KV cache", says:
   - "every `usage` this backend's `Executor` constructs hardcodes `cachedTokenCount: 0`"
   - "there is no `KVCache`, prompt cache, or any persisted-across-turns state anywhere in `Libraries/MLXFoundationModels` (confirmed by grep: zero hits for `KVCache`/`promptCache`/`trim(`/`savePromptCache`)"
   - "It is currently expected to fail against the pinned revision"
   - It names the pinned revision as branch `mlx-foundationmodels`, revision `e6ccd2721`.

2. `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, inside `secondTurnReusesFirstTurnsKVCache`, says: "a zero cachedTokenCount here means the executor-level KV-cache-reuse fix (tracked separately against the vendored mlx-swift-lm fork) has not landed against the pinned commit".

## What is true

The `IntegrationTests` package pins the fork at branch `stable`, `ba8ff43b`. That revision carries `Libraries/MLXFoundationModels/ExecutorPromptCache.swift` (fork commit `08a120e`, "feat(foundation-models): reuse the prompt cache across turns"), and `MLXLanguageModel.swift` there stamps `cachedTokenCount: promptCache.reusedTokenCount`, not a hardcoded 0.

The fix HAS landed. It does not engage for `RealModels.standard`. `ExecutorPromptCachePlan.make` refuses any input whose tokens have `ndim != 1` or whose mask is not nil, and `MuseGlimmerProcessor.prepare(input:)` gives a rank-2, all-ones-masked input on its text-only branch. The whole evidence chain is on `^de1yq0p`, and the correction is filed on the fork's own board as `^7fy0d2z`.

## A second thing to record

The two packages of this repository resolve the same `stable` branch to DIFFERENT revisions: the root package sits at `acc9205`, which predates `ExecutorPromptCache.swift`, and `IntegrationTests` sits at `ba8ff43b`, which carries it. `Package.resolved` is gitignored, so this is local resolution drift, not a tracked defect. It still means the two `swift test` commands of one machine can build two different fork revisions, which makes a failure hard to reproduce. Say so where a reader will meet it.

## Acceptance Criteria

- [ ] `plan.md` states the real reason the test is red, and names the revision that carries the prompt cache
- [ ] The comment in `secondTurnReusesFirstTurnsKVCache` names the real reason and points at the fork card
- [ ] Neither text claims the fork has no prompt cache
- [ ] The assertion itself is unchanged
- [ ] The pin divergence between the two packages is recorded where a reader meets it #integration #real-model