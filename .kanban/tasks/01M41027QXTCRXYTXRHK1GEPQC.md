---
comments:
- actor: claude-code
  id: 01m444evs1ddjq59bf5nebhzfe
  text: |-
    ### implement — changed
    - New events: `SessionEvent.compactionStarted(CompactionStart)` and `SessionEvent.compactionFailed(CompactionFailure)`. `compaction(CompactionResult)` stays the completed event. The three events carry the same id.
    - `CompactionStart`: `id`, `reason: CompactionReason` (`.triggerReached`, `.contextOverflow`, `.toolResultYield`, `.outputCeilingStop`).
    - `CompactionFailure`: `id`, `reason`, `outcome: .cancelled | .failed(String)`.
    - A manual `compact()` sends no compaction event (optional part, not done). This keeps the manual path of the agent free of duplicate entries.
    - evidence: `swift test` — 1476 tests in 185 suites passed, 2 known issues (these were there before).
  timestamp: 2026-10-04T18:57:41.665616+00:00
position_column: done
position_ordinal: ffffffc480
title: 'A host cannot show an automatic compaction while it runs, or one that fails or is cancelled: add compactionStarted and compactionFailed events'
---
## Problem

A host cannot show an automatic compaction while it runs, and cannot show one that fails or is cancelled.

Router gives only `SessionEvent.compaction(CompactionResult)`, and only after an automatic compaction (the proactive fold, the overflow retry, the compaction yield) is complete. A failure or a cancel of an automatic compaction throws out of the answer with no event and no compaction id.

Consumer: FoundationModelsACPAgent ^e8hafh0 (done) reports each compaction as an ACP `compaction_update` entry (owner decision 2026-10-02: a compaction changes only the model context; the ACP history keeps every message, and a compaction shows as one more entry). For a manual `/compact` the agent sends `in_progress`, then `completed` / `failed` / `cancelled`. For an automatic compaction it can send only the terminal `completed` update, and a failed or cancelled automatic compaction gives no entry at all — only the stop reason of the prompt. Its tracking card is ^fhwk6sn.

## What to do

1. Add a session event before an automatic compaction runs, for example `SessionEvent.compactionStarted(CompactionStart)` with the compaction id (the same id that the later `CompactionResult.id` carries) and the reason (proactive fold, overflow retry, yield).
2. Add a terminal event for a compaction that does not complete, for example `SessionEvent.compactionFailed(CompactionFailure)` with the id, and a reason that tells a failure (with the error) from a cancel. Alternatively, make the thrown error name the compaction id; an event is better, because a host projects events in one place.
3. Keep `compaction(CompactionResult)` as the completed event, with the same id.
4. Emit the same events for a manual `compact()` call, so a host can use one path (optional; the agent sends its own updates for the manual path now).

A new `SessionEvent` case breaks hosts with a total switch; that is acceptable (the owner said compatibility is not a concern).

## Tests

- A proactive fold emits `compactionStarted(id)` before `compaction(result)` with `result.id == id`.
- An overflow retry and a yield do the same.
- A summarizer failure during an automatic compaction emits `compactionFailed(id, .failed(error))` and no `compaction(result)`.
- A cancel during an automatic compaction emits `compactionFailed(id, .cancelled)`. #compaction