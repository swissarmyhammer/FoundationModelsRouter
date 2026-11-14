---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Stream the response text of an allowed tool turn so the repetition watch can see it live
---
## Problem

The repetition watch (`RoutedSessionActorRepetitionWatch`) reads the live `LanguageModelSession.transcript` while a model call runs. On the MLX path it never sees response text until the pass is over: mlx-swift-lm buffers the response text of an allowed tool turn. In `Libraries/MLXFoundationModels/MLXLanguageModelGeneration.swift` (stable e7e3ed8), `runAllowedToolGeneration` adds every `.response(text)` event to `result.responseText` (`consumeProtocolEvent` / `consumeAllowedEvents`) and streams only reasoning (`emitReasoning`) during the decode. `runAllowedToolTurn` then calls `emitResponse(result.responseText, …)` once, after generation ended. Every Router session has tools, so every pass takes this path.

Effect: a response-text loop runs to the token ceiling with no stop. Recursive Flint on django-13447 (2026-11-14, transcript `FoundationModelsACPAgent/bench/preds.flint1.transcripts/django__django-13447/01M7DNSKBHGQ8K547VC8M5638S/transcript.jsonl`, seq 707 and 1140) looped on apology lines for 16,384 tokens, about 2.7 minutes of decode each time. The same gap disables two Router stops on this path:
- the response-cycle stop of ^bsz6wn6, which stops this loop within about 225 to 300 tokens once the text is visible;
- the stray-`</think>` stop of ^07vtf4a.

Both have hermetic tests that pass, because their scripted executors stream the response.

## Wanted

The allowed tool turn streams response text to the channel as it decodes (the `.response` events of the router or the protocol decoder are already incremental), into the response entry `entryID`, so the live transcript grows with it. Keep the current contract where it matters:
- the response text that comes before a tool call;
- the schema fallback (`runSchemaGeneration`), which today replaces the response text;
- `endedInsideReasoning`, which emits incomplete output.

Decide each of these explicitly and test it. Note that a streamed text cannot be taken back. Then confirm in the Router that a response loop through the live MLX path stops through `transcriptUpdates()`.

## Notes

- The change is in mlx-swift-lm (the flint/stable branches the Router tracks). Per the breaking-push rule, message the dependent package sessions before pushing.
- No real-model runs on the shared GPU for the unit tests. Use the package's own hermetic executor tests.