---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7dgw0z09566h5spam2x6npf
  text: |-
    Research done. Plan:
    - New public `ReasoningControl` (switchable/alwaysOn/none) in Session/ReasoningOffRequest.swift; protocol `ReasoningSwitchable.canTurnReasoningOff()` is replaced by `ReasoningControlReporting.reasoningControl()`. MLX maps `promptStrategy` (nil config -> none), llama maps template-supports-thinking -> switchable else none.
    - `LanguageModelSessionBackend.reasoningControl()` (default `.none`), forwarded by HookLayeredSessionBackend; the live MLX backend reads its raw model. `callTurnsReasoningOff()` now asks `== .switchable`.
    - Summarizer: `CompactionSummarizerSlot.reasoningControl`; `CompactionCall.outputCeiling(for:)` adds `ReasoningControl.thinkingAllowance` (2048) for `.alwaysOn`, still capped by room; flash rule (room >= allowed) unchanged. The session reads each tier's control in `summarizerTiers()`. `TranscriptCompaction.run` (RealModelSupport, used by the StandardModel case 1) must also pass the control, else Flint case 1 still fails.
    - Recovery: `runOpenedSubmission` reads the backend control when the attempt asks for reasoning off; alwaysOn -> no ReasoningOffRequest, and the watch's detector gets a first-pass reasoning limit (the allowance) in place of `reasoningTokenLimit` until the attempt's first tool call. Switchable/none keep binding the request as today.
    - Non-obvious: the reasoning-limit watch spans the whole model call (all passes of its tool loop), so "for that pass" needs a first-pass marker in the detector: entries before the first `.toolCalls` entry of the attempt.
  timestamp: 2026-11-14T17:14:51.232436+00:00
- actor: claude-code
  id: 01m7dhd1yrp6t1dngfczhdndsz
  text: |-
    Implementation landed (TDD: new tests failed on ceiling, detector and the alwaysOn session recovery before the change; the mapping tests were written with their types).
    - `ReasoningControl` (public, Session/ReasoningControl.swift) with `thinkingAllowance = 2_048`; `ReasoningControlReporting` replaces `ReasoningSwitchable`; `RecoveryFirstPass` maps a control to `.reasoningOff` (switchable, none) or `.thinkingBudget(reasoningTokenLimit: thinkingAllowance)` (alwaysOn).
    - `LanguageModelSessionBackend.reasoningControl()` (default `.none`); live backend reads the raw model, HookLayered forwards.
    - Summarizer: `CompactionSummarizerSlot.reasoningControl`; ceiling = min(allowed + allowance-if-alwaysOn, room); flash still needs room >= allowed. `summarizerTiers()` is now async throws and reads each tier's control. `TranscriptCompaction.run` (RealModelSupport) reads the control too, so StandardModel case 1 on Flint gets the allowance.
    - Recovery: `runAttemptModelCall` in RoutedSessionActorAnswerExecution; detector gets `firstPassReasoningTokenLimit`, applied until the attempt's first `.toolCalls` entry (`WatchedText.isToolCalls`).
    - One existing test updated: RepetitionDetectorTests `attemptTextsReadToolCalls` expects `isToolCalls: true` on a tool-calls WatchedText.
    - Filed ^jw0yqvg for the separate finding (recovery prompts name tool calls in sessions with no tools).
    - Not run: IntegrationTests (GPU shared); orchestrator runs `swift test --package-path IntegrationTests --filter StandardModel`.
  timestamp: 2026-11-14T17:24:09.304067+00:00
- actor: claude-code
  id: 01m7dhd5p2tqhdm6mcexqyfwpw
  text: |-
    ### implement — changed
    - evidence: `swift build --build-tests` clean (0 warnings outside the pre-existing mlx bundle "missing creator" build note); `swift test` 2699 + 42 + 19 tests passed, 0 failures. 21 files: Sources Compaction/{Compactor,Summarization}.swift, Resolution/LiveModelLoader.swift, Session/{ReasoningControl (new),ReasoningOffRequest,LanguageModelSessionBackend,HookLayeredLLMContainer,RepetitionDetection,RepetitionDetector,RoutedSessionActor,RoutedSessionActorAnswerExecution,RoutedSessionActorCompaction,RoutedSessionActorReasoningStop,RoutedSessionActorRepetitionWatch}.swift; Tests AlwaysReasoningThinkingBudgetTests.swift (new), Helpers/{StagedReasoningModel,RepeatingReasoningModel}.swift, LiveLLMContainerGGUFTests.swift, RepetitionDetectorTests.swift, WriteAheadToolCallTests.swift, FoundationModelsRouterRealModelSupport/TranscriptCompaction.swift
    - next: review; orchestrator runs the StandardModel integration suite
  timestamp: 2026-11-14T17:24:13.122483+00:00
- actor: claude-code
  id: 01m7dkqnhfpaaje08syqjpsb0m
  text: |-
    ### verify — green
    - evidence: `swift test` passed 2699 + 42 + 19 tests. `swift test --package-path IntegrationTests --filter StandardModel` passed 5 tests × 2 models (Qwen3.8-27B mxfp4 and flint-oQ8e) in 328 s.
    - The allowance was raised from 2,048 to 8,192. With 2,048, all three Flint compactions came back `.emptySummary`. Flint reasoned about 7,500 tokens before a 181-token summary (summarizer ceiling 7789).
    - Compaction cases 2 and 3 now use `CompactionTestWindow`: for an always-reasoning model the window grows by the allowance, and the trigger and target keep their token counts.
    - next: ^jw0yqvg (the recovery prompt names tool calls in sessions with no tools).
  timestamp: 2026-11-14T18:04:54.191962+00:00
position_column: done
position_ordinal: ffffffffff8f80
title: Give always-reasoning models a thinking budget where the router asks for reasoning off
---
## Problem

Recursive Flint (`mlx-community/flint-oQ8e`, mlx-swift-lm `flint` branch, `reasoningConfig.promptStrategy == .alwaysOn`) cannot turn its reasoning off. The mlx session tested a closed `<think></think>` prefill, and Flint keeps reasoning in plain text after it, so there is no prompt-level fix.

The router asks for reasoning off (`ReasoningOffRequest`, `.custom("no_think")`) in two places, and both assume the request works:

1. **The compaction summarizer** (`Compaction/Summarization.swift` `CompactionCall.outputCeiling(for:)`, `Compactor.planAndSummarize`, `respondWithoutReasoning`). The ceiling is the allowed summary size, about 150 tokens in the tests, and "a reasoning model fits its thinking inside the same ceiling". Flint spends the whole ceiling thinking, and the summary comes back empty: `SummarizationError.emptySummary`.
2. **The recovery after a reasoning stop or a repetition stop** (`Session/RoutedSessionActorReasoningStop.swift`, `RoutedSessionActorRepetitionWatch.swift:651/655/687`, `reasoningOff: true`). The first pass of the recovery is supposed to run with reasoning off and act. Flint reasons again, hits the limit again, and burns all its recoveries.

`canTurnReasoningOff()` (`Resolution/LiveModelLoader.swift`, `ReasoningSwitchable`) is `false` for both `.alwaysOn` and `.none`, so the router cannot tell an always-reasoning model from a model that never reasons.

## Evidence

- `swift test --package-path IntegrationTests --filter StandardModel`. Qwen3.8 passes all 5. Flint passes the tool answer and fails 4:
  - the 3 compaction cases, with `.emptySummary`;
  - `recoveryAfterReasoningStopCallsATool`, with `actedAfterRecovery` false.
- Benchmark at `--max-tokens 256`: every Flint answer took 4 generation calls, because the recovery re-triggered.

## Decision (user, 2026-11-14): a thinking budget

- Distinguish an always-reasoning model.
  - Replace or extend `canTurnReasoningOff()` with a three-way reasoning control: `switchable`, `alwaysOn`, or `none`.
  - MLX reads it from `promptStrategy`: `.templateFlag` maps to `switchable`, `.alwaysOn` to `alwaysOn`, `.none` to `none`.
  - llama.cpp: a template that supports thinking maps to `switchable`, anything else to `none`.
- **Summarizer.** For an always-reasoning summarizer, the output ceiling is the allowed summary size plus a thinking allowance (about 2048 tokens, one named constant), still capped by the room the window leaves. The flash-tier rule stays: the flash tier runs only when the room holds the allowed summary size. The summary must be the response text only, never the reasoning.
- **Recovery.** For an always-reasoning model, the first pass of the recovery cannot run with reasoning off. Instead it runs with reasoning on, under a reasoning allowance (the same constant) in place of the session's `reasoningTokenLimit` for that pass, so it can think briefly and then act. The final pass gets the same treatment. Switchable models keep today's behavior exactly.
- The recovery prompt (`reasoningStopContinuationPrompt`) says "one tool call … or your final answer". Leave the wording alone unless the change needs it. A separate finding: it names tool calls in sessions with no tools.

## Done when

- Hermetic unit tests cover the three-way control, the summarizer ceiling for each control, and the recovery limit for an always-reasoning model. A switchable model is unchanged.
- `swift build --build-tests` and `swift test` are green.
- Do not run the real-model integration suites: the GPU is shared. The orchestrator runs `swift test --package-path IntegrationTests --filter StandardModel` afterwards.
- Do not commit; the orchestrator commits.