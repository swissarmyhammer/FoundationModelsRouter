---
depends_on:
- 01KY5TAEDY4T6P7F7848CWWVAJ
- 01KY5TAEK123W9Y7VPM9DRP1RZ
position_column: todo
position_ordinal: '8e80'
title: 'Prompt queue: enqueue, inspect, edit, cancel, and driver dispatch of queued user prompts'
---
## What

The user-facing half of the session outbox: queue user prompts while the model is busy (or while background work runs), let the app inspect/edit/cancel them before they are sent, and give the driver a pull surface to dispatch them as turns.

- `RoutedSession` API over the outbox's turn-starting items (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`):
  - `enqueue(prompt:) -> id` — stage a `Transcript.Prompt` (or String convenience) for a future turn; strictly FIFO, never coalesced.
  - `pendingPrompts() -> [(id, prompt)]` — snapshot for UI display.
  - `cancel(id)` / `replace(id, prompt)` — mutate a queued prompt before dispatch. The commit boundary is the outbox's `drainForDispatch()` inside the serial-gated chokepoint: once an item is drained its turn is underway; `cancel`/`replace` on a committed id returns a typed already-sent result (follow the repo's error/result conventions), never corrupts an in-flight turn.
- Driver dispatch — the app drives turns, consistent with Router's current character (no hidden auto-turn loop): `dispatchNextPrompt()` runs one queued prompt as a normal recorded turn (composing in any pending turn-riding events per the injection task), returning the response; plus an awaitable "work is waiting" signal (share or extend the outbox's `nextEvent()` surface) so an idle driver loop can `await` then dispatch. Document the intended driver loop shape; an opt-in auto-drain mode is a recorded non-goal for now.
- Queued prompts and their edits are app state until dispatch — nothing lands in the recorded transcript until the turn actually runs (the transcript stays the record of committed turns only).

## Acceptance Criteria
- [ ] Prompts enqueued while a turn is in flight dispatch afterward in FIFO order, one recorded turn each
- [ ] `pendingPrompts()` reflects enqueue/edit/cancel; a cancelled prompt never produces a turn; a replaced prompt dispatches its edited content
- [ ] `cancel`/`replace` racing dispatch: on a committed id returns already-sent; the in-flight turn is unaffected
- [ ] `dispatchNextPrompt()` composes pending turn-riding events into the queued prompt's turn (integration with the injection work verified by a test)
- [ ] The recorded transcript contains only dispatched turns — no trace of cancelled or still-pending prompts
- [ ] Public API documented; `swift test` green

## Tests
- [ ] Unit tests in `Tests/FoundationModelsRouterTests/` — FIFO dispatch, edit/cancel lifecycle, commit-boundary race (enqueue/cancel during an in-flight turn via the fake backend), event composition, transcript purity
- [ ] `swift test` fully green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running