---
comments:
- actor: claude-code
  id: 01m20y174aw89dk79km4j807j8
  text: |-
    Picked up. Research.

    The discarding paths, all found by a read of the two recorders and their readers:

    1. `RoutedSessionActor.recordTranscriptDelta` (Session/RoutedSessionActorRecording.swift), divergence branch: one `divergence` marker, no diff, baseline reset. The turn's entries are lost and the wire gets no `SessionEvent` for them.
    2. The same function, shrink branch (`entries.count < persistedEntryCount`): no marker, no diff, `persistedEntryCount = entries.count`, `persistedBaseline = nil`. An entry that the backend holds after the shrink and that was never recorded is then counted as persisted for the rest of the session. It is never recorded.
    3. `RecordingLanguageModelState.diffAndRecord` (Recording/RecordingLanguageModel.swift): the same two branches for the bare handle (`sync(_:)`). The shrink branch sets `lastSeen = current` and records nothing.
    4. `recordFailedTurn` (Session/RoutedSessionActorTurnExecution.swift): the close is a `.response` with `entry: nil`.

    A fifth shape hides behind path 2: `persistedBaseline` starts as `nil` for a root, a fork and a restored session. A shrink with no baseline gives the recorder no identity to diff by. So the baseline is set at construction from `backend.transcriptEntries().prefix(persistedEntryCount)`: for a root that is the empty prefix, for a fork the parent's entries the child's backend was seeded with, for a restore the seed transcript. With that, a baseline always exists and `persistedBaseline` becomes non-optional.

    Decisions:
    - A divergence of any kind (displaced id, rewrite in place, shrink) records the entries whose `Transcript.Entry.id` the baseline does not hold, in transcript order, then one `divergence` marker after them. `TranscriptDiffer.Divergence` gets a `shrank(recordedCount:currentCount:)` case so a shrink is one more divergence and not a separate path. `TranscriptDiffer.diffByEntryId(baseline:...)` is the diff for a diverged turn: the baseline's ids are the recorded set, and the positional prefix is not that set once an id moved.
    - An entry rewritten in place under its recorded id is not recorded a second time: its id is already in the record, and the marker names the id and says its content changed. A second event under one id would make reconstruction read two entries for one id.
    - After a divergence the baseline becomes `Baseline(transcript: current)` and `persistedEntryCount = current.count`. Every entry of `current` is then in the record: either its id was recorded before, or this diff appended it. So the reset loses nothing. The next turn diffs positionally from `current`.
    - The session events for a diverged turn come from the same loop as a plain turn, so `SessionEvent.toolCall` reaches the wire.
    - `recordFailedTurn` appends its close with an entry that mirrors `Transcript.Response(segments: [])`: an id and no segment, the shape of a turn the model answered with nothing. The SDK never appends a `.response` entry with no segment, so `TranscriptEvent.isFailedTurnClose` names the close by that shape (and by `entry == nil` for a recording made before this change). Reconstruction and `newestStampedUsage` read that one predicate, so a restore still skips the close and a restored fill still ignores its stamp.

    The two readers of the close that I change are `TranscriptReconstruction.effectiveTranscript` and `TokenBudget.newestStampedUsage`. The tests that assert `entry == nil` on the close (SessionChokepointTests, TranscriptReconstructionTests) change to assert the entry with no segment.

    No reason to drop an entry was found.
  timestamp: 2026-09-08T16:36:16.138534+00:00
- actor: claude-code
  id: 01m20yw05h458xn9pq2562cr03
  text: |-
    ### implement — changed

    What changed, by file:

    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift`: `recordTranscriptDelta` has no discard branch. It reads `TranscriptDiffer.divergence(from: persistedBaseline, in: current)` and `TranscriptDiffer.partials(...)`, records every partial through the same loop as a plain turn (so `emitSessionEvents` runs for each one), then appends one `divergence` marker after them through the new `appendDivergenceMarker(_:grammar:)`. After the diff, `persistedEntryCount = current.count` and `persistedBaseline = Baseline(transcript: current)`. That reset loses nothing: each entry of `current` either has an id the record already holds, or was appended by this diff. The shrink guard and its `persistedBaseline = nil` reset are gone.
    - `Sources/FoundationModelsRouter/Recording/RecordingLanguageModel.swift`: `diffAndRecord` (the bare handle) is the same shape: unseen entries first, then the marker. Its shrink branch is gone.
    - `Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift`: `partials(baseline:current:divergence:...)` is the one diff both recorders share (positional while not diverged, by entry id once diverged). `Divergence.shrank(recordedCount:currentCount:)` makes a shrink one more divergence. `diffByEntryId(baseline:)` diffs against the baseline ids. `diff(lastSeen:)` and `divergence(lastSeen:current:)` are removed: no production caller remained.
    - `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift`: `persistedBaseline` is non-optional and is set at init from `backend.transcriptEntries().prefix(persistedEntryCount)`, so a root, a fork and a restore all start with a baseline.
    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`: `recordFailedTurn` appends its close with the entry of `Transcript.Response(segments: [])`. The bracket itself is unchanged (see memory `routed-session-cancellation-invariants.md`).
    - `Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift`: `isFailedTurnClose` names the close by shape (response, no text, `ms` set, entry with no segment or no entry for a recording made before this change). `TranscriptReconstruction.effectiveTranscript` and `TokenBudget.newestStampedUsage` read that one predicate.

    No reason to drop an entry was found.

    Tests (all new or updated tests were red before the production change, except the entry-count test, which held already and the card requires):
    - `TranscriptFidelityTests`: `divergedTurnRecordsItsEntriesThenTheMarker` (prompt, `toolCalls` with `argumentsJSON`, response with `ms`, then the marker), `divergedTurnEmitsToolCallOnTheWire` (`SessionEvent.toolCall`, `toolStatus`, `entryRecorded` on the diverged path), `recordedEntryCountNeverFallsAcrossTurns`, shrink tests for the actor, the streaming path and the handle, mid-transcript insertion, in-place rewrite, handle diverged sync.
    - `TranscriptDifferTests`: `shrunkenCurrentIsAShrinkDivergence`, `diffByEntryIdAgainstBaselineMapsOnlyUnseenIds`.
    - `TranscriptEventSchemaTests`: four `isFailedTurnClose` shape tests.
    - `SessionChokepointTests`, `TranscriptReconstructionTests`: the failed-turn close now asserts an entry with no segment.

    - evidence: `swift test --filter 'FoundationModelsRouterTests.TranscriptFidelityTests/|...TranscriptDifferTests/|...TranscriptEventSchemaTests/|...SessionChokepointTests/|...TranscriptReconstructionTests/|...TokenUsageMeteringTests/|...SessionRestorationTests/|...SessionTreeRestorationTests/|...TurnCancellationTests/'` — 158 tests in 9 suites passed. Full `swift test` — 1250 tests in 135 suites passed (2 pre-existing known issues) and 83 tests in 10 suites passed; 0 failed; the only warning is the pre-existing mlx "missing creator for mutated node" notice. 15 source and test files changed, 727 insertions, 240 deletions. Not committed.
    - next: /review
  timestamp: 2026-09-08T16:50:53.745819+00:00
- actor: claude-code
  id: 01m20zncew000g505s0898knsd
  text: |-
    ### test — green

    - `swift package clean` then `swift build --build-tests`: Build complete. 0 warnings in FoundationModelsRouter's own sources. 5 warnings, all pre-existing and from the vendored `.build/checkouts/mlx-swift` sources (1 bundle-metadata warning, 3 `constexpr if is a C++17 extension` in mlx-generated Metal headers), none touch this package's code.
    - `swift test` (root package, hermetic): two swift-testing runs — 1250 tests in 135 suites passed (2 known issues: `RealModelHarness.swift` embedding-stub test and `BoundedWait.swift` wall-clock test, both pre-existing deliberate `withKnownIssue` patterns unrelated to the changed files) and 83 tests in 10 suites passed. Total 1333 tests, 0 failed, 0 skipped. Confirmed the changed suites ran: `TranscriptDiffer: last-seen-vs-current Transcript diff`, `TranscriptEvent.merged`, plus the modified test files (`SessionChokepointTests`, `TranscriptDifferTests`, `TranscriptEventSchemaTests`, `TranscriptFidelityTests`, `TranscriptReconstructionTests`) — all passed, including "a bare handle whose synced transcript rewrites an entry in place and appends a new one records the new entry, then the divergence marker" and "the recorded entry count never falls between two reads of one session, across a shrink, a rewrite, and a failed turn".
    - `swift build --build-tests` in `IntegrationTests` (depends on the root package by path, so it depends on the changed types): Build complete. 0 warnings in package sources (only the same pre-existing mlx-swift bundle warning).
    - `swift test --filter 'FoundationModelsRouterIntegrationTests\.'` in `IntegrationTests` (the real-model target holding `TranscriptReconstructionIntegrationTests`, `RecordedTranscriptCompactionIntegrationTests`, `RecordingHandleIntegrationTests`, `RealToolTurnComparisonTests`, `AutoCompactionTriggerIntegrationTests` — the suites exercising the changed recording/reconstruction/session-actor code against a real model): 34 tests in 17 suites passed after 476.268 seconds. 0 failed, 0 skipped.

    No fixes were needed — the changes for this task introduced no failures and no warnings.

    - evidence: `swift build --build-tests` (root) — Build complete, 0 pkg warnings; `swift test` (root) — 1250+83=1333 passed, 0 failed, 0 skipped; `swift build --build-tests` (IntegrationTests) — Build complete, 0 pkg warnings; `swift test --filter 'FoundationModelsRouterIntegrationTests\.'` (IntegrationTests) — 34 passed, 0 failed, 0 skipped
    - next: ready for review
  timestamp: 2026-09-08T17:04:45.532645+00:00
position_column: doing
position_ordinal: '80'
title: The transcript recorder discards a whole turn on divergence, and it must only append
---
### What

`recordTranscriptDelta` discards a whole turn when its baseline check
fails. There is no case where that is correct. A transcript appends.

Read from `Session/RoutedSessionActorRecording.swift`: when
`TranscriptDiffer.divergence(from:in:)` gives a value, the actor writes
one `divergence` marker, writes **no** diff, and resets the baseline.
Every entry of that turn goes away, and nothing says which entries were
lost.

**Measured cost.** Over 24 transcripts of a 2026-09-07 evaluation run in
`FoundationModelsACPAgent`:

```
toolOutput   409
response      33   (with NO entry: recordFailedTurn appends none)
divergence    29
session       24
instructions  24
prompt         0
toolCalls      0
reasoning      0
```

Not one `prompt`, `toolCalls` or `reasoning` entry in 24 transcripts.
`toolCalls` carries `argumentsJSON`, so the source of every tool call is
gone and a person cannot read what the model asked for.

`emitSessionEvents(for:)` runs over recorded diff partials, and a
divergence makes none, so the wire loses `SessionEvent.toolCall` too.

### The rule

**A transcript only appends. It never discards an entry, for any
reason.**

The turn happened. The record must say so. A divergence is a note ABOUT
the record — it is a second thing to append, never a reason to drop the
first thing.

This card does not ask for the discard to be narrowed, or made
conditional, or kept for a special case. It asks for the discard path to
go away. If a reason to drop an entry is found while doing this work,
stop and write it on this card for a person to judge, because we cannot
think of one.

### What to do

- Delete the branch that writes a marker and no entries. Append the
  turn's entries, then append the `divergence` marker beside them.
- State what the baseline becomes after a divergence, and why. A reset
  that loses entries is not an answer.
- Make `recordFailedTurn` append its `.response` WITH its entry. An
  empty `{}` records nothing and is the same defect in a second place.
- Emit the session events for the appended entries, so the wire carries
  `SessionEvent.toolCall` on this path too.
- Read every other path that can drop an entry, and remove those as
  well. This is one example of the cause, not the whole of it.

- [x] No path writes a marker and no entries
- [x] `recordFailedTurn` appends a response that holds its entry
- [x] The wire carries the tool calls of a diverged turn
- [x] Every other discarding path is found and removed

### Acceptance Criteria

- [x] A turn that diverges is recorded whole: its prompt, its
      `toolCalls` with `argumentsJSON`, and its response with an entry.
- [x] The `divergence` marker stands beside those entries.
- [x] `SessionEvent.toolCall` reaches the wire for a diverged turn.
- [x] No code path in the recorder drops a transcript entry.

### Tests

- [x] A test forces a divergence and asserts the turn's entries are
      appended, and the marker stands beside them.
- [x] A test asserts a recorded `toolCalls` entry holds its
      `argumentsJSON`.
- [x] A test asserts `SessionEvent.toolCall` is emitted on the diverged
      path.
- [x] A test asserts the entry count never falls between two reads of
      one session.

### Why this is separate from its trigger

The companion card asks why the baseline check fails at all. This card
holds whatever that answer turns out to be: the transcript must not lose
a turn for ANY reason. Do the two independently, and land this one even
if the trigger takes longer.

Raised from FoundationModelsACPAgent, card ^jz016kq.