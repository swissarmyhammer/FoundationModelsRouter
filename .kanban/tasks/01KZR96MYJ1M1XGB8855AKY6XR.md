---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzw9fvaqp3tkdy86n87ed2j3
  text: |-
    Research done. Findings:

    - The live pairing rule lives in `completedToolCallId(forOutputEntryId:dispatched:completed:)`, a private static in Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift. Plan: move it to one shared internal helper type, and call it from the live diff path and from the new cold grouping.
    - The cold grouping will use `TranscriptEntryMapper.event(from:)` for each entry. The live diff path uses the same mapper, so call ids, argument JSON, and text flattening cannot drift between the two paths.
    - A compaction boundary is a `.response` entry that carries a `.custom` segment of type `CompactionSegment`. The live `.compaction` row id is `CompactionResult.id`, a ULID that the fold generates and never persists. A cold seed cannot read that id back. The cold row will key on the persisted `CompactionSegment.id` instead, with `sourceEntryId` = the boundary entry id when a summary is present (the same join rule the live `summaryEntryId` uses). This one divergence is documented in code.
    - Live row ORDER for a tool turn differs from transcript order: the answer text streams first, so the live projection appends the text row before the diff appends the tool rows. The cold seed installs rows in transcript order (the correct conversation order for a restored view). The acceptance comparison is row-for-row by id: same id set, and each seeded row equals the live row with that id.
    - Transcript source (proposed-solution item 4): add a read-only `transcript()` accessor to the `RoutedSession` protocol, implemented on `RoutedSessionActor` by reading `backend.transcriptEntries()` under the turn lock (the same lock discipline `fork` uses). The card names this gap directly, so the accessor is the chosen source; seeding from `TranscriptTree.effectiveTranscript` stays possible because `seed(from:)` takes a plain `Transcript`.
    - Test plan (TDD): unit tests for the pure grouping over hand-built entries (response, reasoning, multi-call round, ordinal fallback, unanswered call -> .failed, compaction boundary, prompt/instructions skipped), plus one restore test in the RestoreFidelityTests style: scripted tool turn -> live projection via streamEvents -> fresh-process restoreSessionTree -> seed from restored.transcript() -> compare by id; then one more live turn on the restored session must append without duplication.
  timestamp: 2026-08-13T00:48:54.103506+00:00
- actor: claude-code
  id: 01kzway39v4wnvfermgj8wem81
  text: |-
    Implementation done. What landed:

    - New shared helper `ToolCallOutputPairing.completedToolCallId(forOutputEntryId:dispatched:completed:)` in Sources/FoundationModelsRouter/Session/ToolCallOutputPairing.swift. The live diff path (RoutedSessionActorRecording) and the cold path both call it. The old private copy in RoutedSessionActorRecording.swift is deleted. Doc references in RoutedSessionActorRunJournal.swift point to the new symbol.
    - Pure grouping `SessionProjection.transcriptRows(from:)` in Sources/FoundationModelsRouter/Session/SessionProjection.swift. It maps each entry through `TranscriptEntryMapper.event(from:)` — the same mapping the live diff uses — so ids, argument JSON, and text flattening cannot drift. `.response` -> `.text` row, `.reasoning` -> `.reasoning` row, `.toolCalls` -> one `.toolCall` row per call, `.toolOutput` completes its row through the shared pairing rule, a compaction boundary -> `.compaction` row. A `.prompt` entry resets the pairing scope (the live rule's scope is one turn's diff). After the loop, a call row that stays `.running` becomes `.failed`, the same as the live diff's closing sweep.
    - `SessionProjection.seed(from:)` installs the rows and resets the projection to its fresh state. Live events applied after a seed append normally: each seeded text/reasoning row already carries its adopted entry id, so a later delta opens a new row.
    - Transcript source (item 4): the chosen source is a read-only `transcript` accessor on the `RoutedSession` protocol, implemented on `RoutedSessionActor` under the turn lock (the same lock discipline `fork` uses). `seed(from:)` also accepts a `Transcript` from `TranscriptTree.effectiveTranscript`.

    Two facts a reviewer must know:

    1. Row ORDER: the live projection puts a tool turn's answer text row first, because the text streams before the diff appends the tool rows. The cold seed installs rows in transcript order. The acceptance test compares row for row BY ID (a dictionary join): same id set, and each seeded row equals the live row with that id.
    2. Compaction rows: the live row id is `CompactionResult.id`, a ULID the fold generates and never persists. A cold seed cannot read it back, so the cold row keys on the persisted `CompactionSegment.id`. This is documented on `compactionRow(from:entryId:)`. The tool-turn acceptance is not affected.

    Tests (TDD): Tests/FoundationModelsRouterTests/SessionProjectionSeedingTests.swift — 9 tests. The RED state was verified with `swift build --build-tests` (compile failure on the missing API), then the code landed. One process note: my first `swift test` invocation was piped through `tail`, which discarded the output and masked the exit status, so it produced no evidence; the bare `swift test` run that followed is the verification run.
  timestamp: 2026-08-13T01:14:09.595717+00:00
- actor: claude-code
  id: 01kzway6j4xx2y2rfn2ebvbtxa
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Session/ToolCallOutputPairing.swift (new), Sources/FoundationModelsRouter/Session/SessionProjection.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift, Tests/FoundationModelsRouterTests/SessionProjectionSeedingTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift (doc only). One `swift test` run: 915 + 27 + 24 = 966 tests in 103 suites, 0 failures, exit 0 (1 pre-existing known issue in BoundedWait).
    - next: /review
  timestamp: 2026-08-13T01:14:12.932694+00:00
depends_on:
- 01KZR9658E5CEVBK177RT024HY
position_column: doing
position_ordinal: '8180'
title: Seed SessionProjection from a cold Transcript
---
## Problem

`SessionProjection` builds its rows only from live `SessionEvent`s, through `apply(_:)` (Sources/FoundationModelsRouter/Session/SessionProjection.swift). A restored session (`RoutedModel.restoreSessionTree`) has a full transcript history, but its projection starts empty. The UI shows a blank conversation for a session that has content. This looks broken to the user.

A second gap blocks the fix: `RoutedSession` does not expose its transcript publicly. A caller has no supported way to read the entries it must seed from.

## Proposed solution

1. Write a pure grouping function that maps `[Transcript.Entry]` to `[SessionProjection.TranscriptEntry]`:
   - `.response` entries become `.text` rows.
   - `.reasoning` entries become `.reasoning` rows.
   - `.toolCalls` and `.toolOutput` entries pair into `.toolCall` rows with `.completed` status and the output as summary. One `.toolCalls` entry can hold many calls; make one row per call.
   - A compaction boundary (`CompactionSegment`) becomes a `.compaction` row.
2. Pair each `.toolOutput` to its call by id equality first. When the id names no announced call, fall back to first-occurrence ordinal order — the same rule as `completedToolCallId(forOutputEntryId:dispatched:completed:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift:433). Extract that pairing into one shared internal helper, so the live path and the cold path always agree.
3. Add `SessionProjection.seed(from:)` (or an initializer) that installs the rows. Live events applied after a seed must append normally.
4. Give the seed a transcript source. Choose one and document it: expose a read-only `transcript` accessor on `RoutedSession`, or seed from `TranscriptTree.effectiveTranscript(forSession:registry:view:)`.

## Acceptance

- Restore a recorded tool-turn session, seed a projection, and compare: the seeded rows must equal the rows a live projection produced during the original run, ids included (needs the stable-identity task).
- A live turn after a seed must append rows without duplication. #projection