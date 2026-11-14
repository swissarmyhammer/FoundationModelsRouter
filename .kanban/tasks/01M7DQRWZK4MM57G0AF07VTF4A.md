---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7dr4h4h2xq7tdv362mh9gbs
  text: |-
    Research:
    - Evidence seq 707: the stray `</think>` sits inside a `.response` entry (the reasoning entry closed before it), so MLX's ReasoningEventEmitter already treated the first close as the reasoning's own close; every later `</think>` reaches the router as response text.
    - Executor-channel layer (SessionLanguageModel / PassOutputRelay) rejected: `LanguageModelExecutorGenerationChannel.Event` exposes no public value (the relay reads it by reflection), so a rewrite of a text fragment there would be fragile.
    - Chosen layer: the session's repetition watch (RoutedSessionActorRepetitionWatch), which already reads `WatchedText` of the live transcript in flight and stops the model call. Gate: `backend.reasoningControl() == .alwaysOn` (seam of ^qmewzw0), so switchable (Qwen3) and none are untouched. A `</think>` that closes the reasoning never lands in a `.response` entry, so it is untouched by construction.
    - The stop must NOT recover (unlike repetition/reasoning stops): it records the attempt with the response cut before the tag, finish reason `.completed`, and returns the cut text as the reply. Reuses InFlightTranscript.rebuilt, RepeatedPartRemoval.render(of:applying:) for the cut, and replaceBackendAndRecord.
    - The watch runs only when RepetitionDetection.isEnabled (its documented meaning is "the session watches the calls of its submissions"), so the stray-close stop rides that same switch.
  timestamp: 2026-11-14T19:21:49.969218+00:00
- actor: claude-code
  id: 01m7drhgsx4rz2r0dspvh9qnqw
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsRouter/Session/StrayReasoningClose.swift (new), RoutedSessionActorRepetitionWatch.swift, RoutedSessionActorAnswerExecution.swift, RoutedSessionActorModelCallStop.swift, NoOpToolCallStop.swift, RoutedSessionActorWatchStopUsage.swift, RoutedSessionActorReplacedBackend.swift, RepetitionDetection.swift (doc), Tests/FoundationModelsRouterTests/StrayReasoningCloseTests.swift (new), Helpers/RepeatingReasoningModel.swift, Helpers/StagedReasoningModel.swift. RED: 5 session tests held to the 10 s stop-hold limit with no stop, and the finder test failed. GREEN: `swift build --build-tests` has 0 warnings and `swift test` passes all 2708 + 42 + 19 tests.
    - design: the repetition watch of an `.alwaysOn` model looks at `.response` entries for `</think>`. It cancels the call, cuts the rebuilt transcript before the tag, and records it with `.completed`. The reply is the text before the tag, and no recovery runs. The new `RepetitionWatchState.hasStop` covers this stop in `noStopOutstanding`, in the no-op stop guard and in `checkToolCallForRepetition`. `measureWatchStop` now forwards to the general `measureStoppedCall`, and `ReplacedBackendMeasure.addingStoppedCall(to:)` replaces the inline usage sum.
    - known limits: the stop rides `RepetitionDetection.isEnabled`. The text deltas already streamed are not retracted (no `.textReset`); this follows the existing convention that the reply comes from the last submission. A call that ends by itself before the stop lands keeps its text.
    - next: /review
  timestamp: 2026-11-14T19:28:55.613222+00:00
position_column: done
position_ordinal: ffffffffff9080
title: A stray </think> in the response text of an always-reasoning model ends the turn
---
## Problem

Recursive Flint (`mlx-community/flint-oQ8e`, always-reasoning). In Flint's tokenizer `<think>` and `</think>` are plain text, not special tokens: ids 150006 and 150007, `special: false`.

On a status turn the model writes its status line, then a literal `</think>`, then continues. It fabricates the next router feedback message in its exact shape (`[agents] agents (<id>) running: {…}` / `completed: …`), invents an agent verdict, and loops until the 16,384-token ceiling. The `</think>` stays in the response text.

## Evidence

From the FoundationModelsACPAgent SWE-bench run of Flint on django-13447 (Router edd974ae, mlx stable e7e3ed8), transcript `FoundationModelsACPAgent/bench/preds.flint1.transcripts/django__django-13447/01M7DNSKBHGQ8K547VC8M5638S/transcript.jsonl`:

- seq 707, a 63,740-char response: "Waiting on the plan checker agent. Its completion token is `01M7DP2Z…`.</think>[agents] agents (01M7DP2Z…) running: {…}\n[agents] agents (…) completed: Agent double-check … finished.\n\nVerdict: PASS …" followed by hundreds of "I am sorry. I am stopping now."
- seq 1140: the same shape after "Waiting on the coder agent. …", 61,192 chars.
- seq 709: generationCall reports 16,384 tokens, stopped at the token ceiling, 164 s.
- Both runaways lost about 3 minutes. Qwen3.8 never does this on the same instance.

## Wanted

For a model whose reasoning closes with a plain-text `</think>`, a `</think>` that appears in the response text, after the reasoning is already closed, ends the pass:
- the session stops the model call at it;
- the tag and anything after it are dropped from the reply;
- the turn ends as if the model had ended it.

Find where the response text is watched (`RoutedSessionActorRepetitionWatch`, `WatchedText`) or parsed, and choose the right layer. The fix must not touch a model where `</think>` is a special token handled by the reasoning parser, and it must not touch a `</think>` that is the reasoning's own close.

## TDD

Write the failing hermetic test first: a scripted model that writes "status.</think>[agents] fabricated…". Then implement. Done when `swift build --build-tests` and `swift test` are green. No real-model runs: the GPU is shared.