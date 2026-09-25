---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3cyx4ssskmcd10weq94j9jb
  text: |-
    From the design task ^jdp02p (2026-09-25, `generation-queue.md` sections 5.1, 5.3 and 5.5): what changes for this task.
    - The item of the queue becomes one submission to Foundation (one whole SDK call), not one pass (^1psqdm9). A summarizer call is thus one submission on the queue of the container that runs it. ^1psqdm9 step 3 builds that. This task now depends on ^1psqdm9, so it tests the final shape and does not test the per-pass shape twice.
    - AC1 (flash summarizer and a flash submission of another session never overlap) stays.
    - AC2 (own-model summarizer between two passes completes): restate it as "between two submissions". In the new model a compaction never runs inside a submission: the proactive check, the yield, the ceiling stop and the overflow retry all compact at the pump, between two submissions. The own-model summarizer thus never waits for its own session.
    - AC3 (cancel during a summarizer wait cancels via `isTurnCancelled`): until ^3qx0mpt the predicate is `isTurnCancelled`; after it, the predicate keys on the running answer. Keep the rule: key on the predicate, never on the type of `CancellationError`.
    - Step 2 (doc of `performAutoCompaction`) must name no `turnLock` and no `generationGate`.
  timestamp: 2026-09-25T18:58:06.265176+00:00
depends_on:
- 01M39ZNSNZGBYEY5G8R93KJN94
- 01M3CYJ4VS4VF5EEHA01PSQDM9
position_column: todo
position_ordinal: '8480'
title: Run each compaction summarizer call as a queue item on the queue of its own container
---
## Why

Now the flash-tier summarizer runs under the gate of the CALLING model, not of the flash container. `performAutoCompaction` (`Session/RoutedSessionActorCompaction.swift`) builds it from `profile.flash.container.makeSession(...)` while the turn holds its own model's gate. A flash generation of another session can thus run at the same time on the flash model. This is a defect. Design: `generation-queue.md`, section 2.

With the executor-level queue, a backend made by the flash container gets the flash queue (^8csj2hw makes one queued wrapper for each backend, over the queue of its container). Thus most of the fix comes from the queue task. This task proves it and covers each compaction path.

## What to do

1. Check each compaction path: turn-start compaction, compaction between passes (tool-result boundary), ceiling-stop compaction, overflow retry, and the caller `compact(prompt:budget:)` in `RoutedSessionActorCompaction.swift`. Each summarizer call must be one queue item on the queue of the container that runs it, and must not wait while its own session holds a place on the same queue (self-deadlock).
2. Update the doc comment of `performAutoCompaction` ("The caller must already hold ``turnLock`` and a ``generationGate`` permit").

## Acceptance Criteria

- [ ] A test shows the flash summarizer waits on the flash queue: a flash pass of another session and the summarizer never overlap.
- [ ] A test shows the own-model summarizer, called between two passes of a turn, completes (no self-deadlock).
- [ ] A cancel during a summarizer wait for a queue place cancels the turn (`isTurnCancelled` path). #generation-queue