---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
title: The retention cut truncates the default CompactionPrompt's sectioned summary mid-section on small spans, and the truncated scaffold derails the next turn
---
Found on 2026-08-19 while task ^nwe0qt1 rebuilt the CompactionDemo.

## What was measured

A fold over a span of about 630 estimated tokens, summarized by `mlx-community/GLM-4-9B-0414-4bit` with `CompactionPrompt.default` (the eight-section scaffold): the model wrote a faithful sectioned summary, but the sectioned form is long, so `Summarization.cut(_:toCharacters:)` truncated it in the middle of section 3 ("index is rebuilt from"). The stored summary therefore ends mid-sentence inside a numbered scaffold.

The session model (`Llama-3.2-1B-Instruct-4bit`, greedy) then read the truncated scaffold as its context and degenerated on its next turn: the reply was "Nightjar Nightjar Nightjar ..." repeated to the token ceiling. The same fold with a one-paragraph prompt (`compactionPrompt:` override) fit inside the cut and the next turn stayed coherent.

## Why this matters

`cut(_:toCharacters:)` is documented as a safety bound. On a SMALL span the retention allowance (0.8 of the span) is small, and the default prompt's sectioned output regularly exceeds it, so the cut becomes the routine path rather than the safety net. A cut that ends mid-list is worse context than a shorter summary the model finished.

## What to decide

1. State the summary budget to the model in a way it can honor without the `^azd033m` failure mode, or
2. Cut at a SECTION boundary rather than a sentence boundary when the text carries the scaffold, or
3. Scale the prompt's section count down for small spans.

## Acceptance criteria

- [ ] A fold's stored summary never ends inside an unfinished section or sentence, or the trade is documented with a measurement
#compaction