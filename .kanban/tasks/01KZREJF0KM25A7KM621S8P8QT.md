---
assignees:
- claude-code
depends_on:
- 01KZPW9RY91W2KAMGY3W8DZVEE
position_column: todo
position_ordinal: a080
title: Ship a turn-outcome API so callers stop re-implementing the event fold
---
## Problem

Driving one turn correctly while observing it requires knowledge the library keeps private. The CompactionDemo needs a 40-line `runTurn` helper (Examples/CompactionDemo/main.swift:53-91): a switch over all eight `SessionEvent` cases, including the subtle `textReset` accumulation rule — forget that rule and the assembled reply silently contains text the model abandoned. `SessionProjection.apply(_:)` implements the same fold for SwiftUI, so the logic now exists twice, and every event-stream consumer will write it a third time. Four output paths exist (`respond`, `streamResponse`, `streamEvents`, `streamSessionEvents`) and none of them is the easy correct one for a caller that wants the reply text PLUS awareness of tools, folds, and usage.

## Proposed solution

1. Add one high-level entry point that owns the fold — for example: `func respond(to prompt: String, observing: ((SessionEvent) -> Void)? = nil) async throws -> TurnOutcome`.
2. `TurnOutcome` carries: the final reply text (with the `textReset` rule applied, character-equal to `respond(to:)`), the closing `TokenUsage`/`contextFill`, every `CompactionResult` the turn folded, and the turn's tool invocations (id, name, arguments, status, summary).
3. Implement it ON the existing `streamEvents` path — it is a consumer, not a new turn mechanism. The optional `observing` callback still delivers each raw event live, for callers that want both.
4. Rewrite the CompactionDemo's `runTurn` to one call, proving the API removes the boilerplate it was born from.
5. Extract the fold into one internal reducer shared with `SessionProjection.apply(_:)`, so the rule exists once.

## Acceptance

- The CompactionDemo drives its turns through the new API; the local `runTurn` helper is deleted.
- A test proves `TurnOutcome.reply` equals `respond(to:)`'s return for the same scripted tool-using turn.
- `SessionProjection` and `TurnOutcome` produce their text from the same shared reducer, pinned by a test. #api