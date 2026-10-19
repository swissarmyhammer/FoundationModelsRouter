---
comments:
- actor: claude-code
  id: 01m5azv9xyy8v0r0apbn7t32me
  text: |-
    Research:
    - `performCompaction` sends `compactionStarted`, and `runCompaction` sends `compaction` or `compactionFailed`. Both triggers (`compact()` and `compactInsideAnswer`) go through them. An automatic compaction that a stop reached before it started sends no event, so it sends no hook event either.
    - `CompactionStarted(compactionID:reason:)` and `CompactionEnded(compactionID:outcome:)` are in FoundationModelsHooks. `CompactionOutcome` is `.completed(tokensBefore:tokensAfter:)`, `.failed(message:)`, `.cancelled`.
    - `HookDispatcher.post` drops an event for a key that has no queue. `close()` calls `hooks?.end()` (SessionEnd) after the drain, and the drain waits for the compaction, so `CompactionEnded(cancelled)` goes out before `SessionEnd`.
    - The compaction fixtures (`AnswerCancellationTests.makeFixture`) make a Router with no hooks. The plan adds a `hooks:` parameter (default `nil`) to `makeFixture`.
  timestamp: 2026-10-19T21:07:29.342109+00:00
- actor: claude-code
  id: 01m5b05xwhakeryzm0v1j2md34
  text: |-
    Implementation landed (TDD):
    - RED: `swift test --filter FoundationModelsRouterTests.CompactionHookTests` ran 5 tests. 4 failed because the visitor got no events (`hooked.visitor.events → []`). The no-dispatcher test passed, as it must.
    - New `SessionHooks.post(_:)`: it sends a post event only while the session is open and its `SessionStart` went out. Thus a session whose dispatcher had no visitor at start sends no compaction events. If it did, the dispatcher would drop and log each event, because the key has no queue.
    - New `Session/CompactionHookEvents.swift`: `CompactionStarted.init(_ start: CompactionStart)`, `CompactionEnded.init(_ result: CompactionResult)`, `CompactionEnded.init(_ failure: CompactionFailure)`, `CompactionOutcome.init(_ outcome: CompactionFailure.Outcome)` (exhaustive switch, no default).
    - `performCompaction` posts `CompactionStarted` after the `compactionStarted` session event. `runCompaction` posts `CompactionEnded` after `compaction` or `compactionFailed`. No change to the cancel logic, the pump or the pass logic.
    - Test fixture: `AnswerCancellationTests.makeFixture` gets `hooks: HookDispatcher? = nil`, which it gives to the Router.
    - The close test passes: close calls `hooks?.end()` only after its drain, so `CompactionEnded(cancelled)` comes before `SessionEnd`.
    - GREEN: the filtered run gave 5 of 5 passed, with no compiler warnings. The full `swift test` gave 1881 tests in 234 suites passed (9 known issues that were there before), 26 in 14 suites passed, and 19 in 3 suites passed.
  timestamp: 2026-10-19T21:13:17.457843+00:00
- actor: claude-code
  id: 01m5b0604j3b8d83957b39t0xd
  text: |-
    ### implement — changed
    - evidence: 5 files. Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift, Sources/FoundationModelsRouter/Session/SessionHooks.swift, Sources/FoundationModelsRouter/Session/CompactionHookEvents.swift (new), Tests/FoundationModelsRouterTests/CompactionHookTests.swift (new), Tests/FoundationModelsRouterTests/AnswerCancellationFixtures.swift. Ran `swift test`: 1881/234 + 26/14 + 19/3 passed, 0 failures.
    - next: /review
  timestamp: 2026-10-19T21:13:19.762551+00:00
- actor: claude-code
  id: 01m5b08e3qet25v5hyppe12sg4
  text: |-
    ### test — green
    - evidence: touched the 5 changed Swift files; root `swift test`: 1881 tests in 234 suites passed (9 known issues in old tests that check failure paths on purpose, not from this change); 26 and 19 tests in the two other runs passed; 0 failed, 0 skipped. The 4 tests in suite "Compaction hooks: CompactionStarted and CompactionEnded" passed. `cd IntegrationTests && swift build --build-tests`: Build complete, 0 errors. The only warning in both builds is the known mlx "missing creator" line.
    - next: review
  timestamp: 2026-10-19T21:14:39.607713+00:00
depends_on:
- 01M5ARTSQ3ZSQMRH1Z5QSTWWJ1
position_column: doing
position_ordinal: '80'
title: Router emits CompactionStarted and CompactionEnded
---
## Context
This card is a Router change for the hook system that was designed in a FoundationModelsACPAgent session (2026-10-19). The user approved this change on 2026-10-19. It needs the Router card "Router holds a HookDispatcher, gives it to each session, and emits SessionStart and SessionEnd".

## What
Emit `CompactionStarted` and `CompactionEnded` (both post) in `performCompaction` (`Session/RoutedSessionActorCompaction.swift`), next to the `compactionStarted`, `compaction` and `compactionFailed` session events. Both triggers go through it: the manual `compact()` and the automatic compaction inside an answer (`compactInsideAnswer`). Compaction has no pre event: an automatic compaction starts because the context is almost full, and a block would make the next pass overflow. Use symbol names, not line numbers.

- `CompactionStarted`: `compactionID` (the id of the `compactionStarted` session event) and `reason`.
- `CompactionEnded`: the same `compactionID`, and `completed(tokensBefore:tokensAfter:)`, `failed(message)` or `cancelled`. Map `CompactionFailure.Outcome.cancelled` (for example, `close()` cancels the summarizer) to `cancelled`, and `.failed(String)` to `failed(message)`.

## Acceptance Criteria
- [x] A manual `compact()` gives `CompactionStarted` and then `CompactionEnded(completed)` with the same `compactionID`.
- [x] An automatic compaction inside an answer gives the same two events.
- [x] A compaction that fails gives `CompactionEnded(failed)`.
- [x] A `close()` during a compaction gives `CompactionEnded(cancelled)`.
- [x] With no dispatcher, the compaction tests pass unchanged.

## Tests
- [x] `Tests/FoundationModelsRouterTests/CompactionHookTests.swift` (Swift Testing): each criterion above, with the scripted compaction fixtures that the compaction tests use now.
- [x] Run `swift test` in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`. All tests pass.

## Workflow
- Use `/tdd`. Write the failing tests first, then implement.

#hooks