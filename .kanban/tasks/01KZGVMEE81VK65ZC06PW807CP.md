---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Gated tool-calling suites lose their tool call or their recall when they inherit another suite's prompt cache
---
Discovered while working `^f9zt7c5`, which proved the mechanism for one suite and fixed only that suite.

`MLXLanguageModel` holds a process-global container cache keyed by model id and, beside it, a per-model `PromptCache` that stores each completed round's KV state as content-addressed chunks **shared across every conversation on that model** (SGLang RadixAttention-style; see `.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/PromptCache.swift`). Every gated suite in `FoundationModelsRouterIntegrationTests` drives the same `RealModels.standard`, so each suite's turn resolves against a chunk pool other suites filled.

`^f9zt7c5` measured what that does to one suite: under a full `FM_ROUTER_INTEGRATION_TESTS=1 swift test` the propagation probe's turn reproducibly emitted **no tool call** and answered `"I have called the context_probe tool with the note 'ping'."` — narrating a call it never made — while the identical turn run alone called the tool every time. Dropping the model (`MLXLanguageModel.evict()`, which purges that model's prompt cache) before the turn restored the real dispatched call, reproducibly.

Sibling suites show the same two signatures and are **not** yet protected. Across four full gated runs on 2026-08-08:

- `RecordingHandleIntegrationTests.toolUsingTurnRoundTripsToDisk` — failed once on `isInOrderSubsequence([.session, .instructions, .prompt, .toolCalls, .toolOutput], ...)`, i.e. its echo turn produced no `.toolCalls` entry at all. Same zero-tool-call signature as the probe's.
- `CompactionSpikeIntegrationTests` — failed once on `reply.contains("42")`: the rebuilt session did not recall a fact its own transcript carried.
- `CompactionRoundTripIntegrationTests` — failed in **all four** runs, including `recall.contains("CRIMSON-77")` → `"I do not have access to the project brief or any vault codes."`. Its fill-threshold assertions are already owned by `^5m97h14`; the *recall* failure looks like this class rather than sizing, so check both cards together.

Which sibling fails varies run to run, so this reads as shared-state flakiness, not a deterministic break. Note also that `^f9zt7c5`'s fix itself now drops `RealModels.standard` mid-run, which perturbs what later suites inherit — measure whether that helps or hurts the siblings rather than assuming.

Two candidate shapes, and the choice is the work:

1. **Per-suite isolation, in this repo.** Give the gated tier one shared "start from a clean model" step instead of one suite knowing the trick — the natural home is `GatedSuiteSerialGate` / `Support/`, which already owns the cross-suite RAM permit and the metallib bootstrap. This is the in-scope option.
2. **A prompt-cache correctness question, in the fork.** If a prefix-matched chunk chain can make a model behave as though a tool call or a fact already happened, that is a `PromptCache` resolution question in `mlx-swift-lm`, not a test-hygiene one. Per standing project rule, anything needing a change in the vendored fork belongs on the fork's own board — file it there, do not attempt it here.

Start with (1) and measure; only escalate to (2) with evidence that isolation is insufficient.

## Acceptance Criteria
- [ ] Determined whether the probe's mid-run eviction helps or hurts sibling suites, measured across repeated full gated runs
- [ ] Cross-suite clean-model isolation lives in one shared place, not duplicated per suite
- [ ] `RecordingHandleIntegrationTests` and `CompactionSpikeIntegrationTests` pass across repeated full gated runs, or their remaining failure is attributed to a named cause
- [ ] The recall half of `CompactionRoundTripIntegrationTests` is attributed either to this class or to `^5m97h14`
- [ ] If the residue is a fork `PromptCache` defect, it is filed on the mlx-swift-lm board and referenced here — not worked in this repo
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Repeated full gated runs are the proof. Gated runs: one at a time, one shell command per run.
#phase-1