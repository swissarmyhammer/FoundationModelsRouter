---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7e2f4mwc6ew9sbcj57zy42y
  text: |-
    ### Recurrence: flint3 (Router 487eeb65, mlx 71692319, Extras fee9093, Skills 1006b82)
    - django-13447, root session 01M7E0Q9RS25HMZNNNNVAYC7K2, generationCall seq 67: fed 18058 (18038 cached), generated 16384, stopped at the token ceiling, left a tool call, callMs 167150 (~170 s). This was the pass right before the first planner start.
    - The tool call that came out was a truncated `agents {"agent": "planner"}` with no `prompt`, and no reasoning entry was kept. So most of the 16k tokens were most likely inside the tool-call body (the `prompt` argument), where the GLM parser holds them. Neither the reasoning watch nor the response watch sees that text.
    - Scope addition: streaming `.response` text alone does not cover this case. The fix also needs a stop for a tool-call body that runs away, decided in mlx (where the parser holds the body). For example, it could stream the tool-call text as it decodes so the router's cycle watch can read it, or put a cap/cycle check inside the tool-call parser. Test it with a hermetic executor that scripts a looping tool-call argument.
    - Next: once the instance ends, read the transcript under FoundationModelsACPAgent/bench/preds.flint3.transcripts/django__django-13447/ to confirm where the tokens went.
  timestamp: 2026-11-14T22:22:23.388392+00:00
- actor: claude-code
  id: 01m7fgaj5te01hfxx4psh7vwre
  text: |-
    ### Decision (user, 2026-11-15): won't do
    "no the only tool that will really have this problem is shell, and this will be in the background via multitool / runCode". A runaway inside a tool-call body is only a real risk for shell commands. Those run in the background through multitool / runCode, so mlx-swift-lm does not need to stream the response text and tool-call bodies of a tool turn.
  timestamp: 2026-11-15T11:43:47.898379+00:00
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