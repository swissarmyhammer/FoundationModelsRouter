---
depends_on:
- 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1
position_column: todo
position_ordinal: '8380'
title: Router emits CompactionStarted and CompactionEnded
---
## Context
This card is a Router change for the hook system that was designed in a FoundationModelsACPAgent session (2026-10-19). The user approved this change on 2026-10-19. It needs the Router card "Router holds a HookDispatcher, gives it to each session, and emits SessionStart and SessionEnd".

## What
Emit `CompactionStarted` and `CompactionEnded` (both post) in `performCompaction` (`Session/RoutedSessionActorCompaction.swift`), next to the `compactionStarted`, `compaction` and `compactionFailed` session events. Both triggers go through it: the manual `compact()` and the automatic compaction inside an answer (`compactInsideAnswer`). Compaction has no pre event: an automatic compaction starts because the context is almost full, and a block would make the next pass overflow. Use symbol names, not line numbers.

- `CompactionStarted`: `compactionID` (the id of the `compactionStarted` session event) and `reason`.
- `CompactionEnded`: the same `compactionID`, and `completed(tokensBefore:tokensAfter:)`, `failed(message)` or `cancelled`. Map `CompactionFailure.Outcome.cancelled` (for example, `close()` cancels the summarizer) to `cancelled`, and `.failed(String)` to `failed(message)`.

## Acceptance Criteria
- [ ] A manual `compact()` gives `CompactionStarted` and then `CompactionEnded(completed)` with the same `compactionID`.
- [ ] An automatic compaction inside an answer gives the same two events.
- [ ] A compaction that fails gives `CompactionEnded(failed)`.
- [ ] A `close()` during a compaction gives `CompactionEnded(cancelled)`.
- [ ] With no dispatcher, the compaction tests pass unchanged.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CompactionHookTests.swift` (Swift Testing): each criterion above, with the scripted compaction fixtures that the compaction tests use now.
- [ ] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks