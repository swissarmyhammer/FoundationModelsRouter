---
comments:
- actor: claude-code
  id: 01m6gt4a04a889e35knr8vz0b2
  text: |-
    DESIGN (no code written yet).

    Finding first: the record already has a durable `SessionFacts.archivedAt` (SessionFacts.swift:37). `RouterSessionDirectory.archive(_:by:)` (RouterSessionDirectory.swift:1717) writes it for a live or a recorded session, and `RecordedSessions.summary(of:)` shows it as `state: .archived`. I do not reuse it, because archive is a user action: it needs a `SessionMessageSender`, it sends `stateChanged` and `archived` events, it cancels work, and a UI hides an archived session. An ended child must stay visible as history.

    Design:
    1. `SessionFacts` gets `public var endedAt: Date?` and `public var endReason: SessionEndReason?`. `SessionEndReason` is a public enum: `finished`, `failed`, `cancelled`. Both keys are written to `index.md` only when set (same pattern as `archivedAt`, SessionRecord.swift:325). A missing key decodes to `nil`: no migration, and a record with no marker counts as not ended.
    2. Public call on `RouterSessionDirectory`: `markEnded(_ id: ULID, reason: SessionEndReason) async throws -> SessionSummary`. It works on a live session (`updateRecord`, as `archiveLive` does) and on a recorded one (`changeRecordedRecord`). It is idempotent: a record that has `endedAt` is not written again and keeps the first reason. It does NOT close the session, cancel work, or send `archived`. The host calls it after the run reaches a terminal state. The write is durable before the call returns.
    3. `close()` never sets the marker. Reason: a close at process shutdown, while a run is working, must stay restorable. The run plane sweep (`RunPlane.sweep()`) journals a terminal event per working run on an orderly close; that is a journal fact about the run, not the session marker, so the two do not conflict. The test proves it: close with a working run, then reload: not ended.
    4. `SessionSummary` gets `endedAt: Date?` and `endReason: SessionEndReason?`, filled by `RecordedSessions.summary(of:)` and by the live summary. A host lists children with `kind == .subagent && parentID == X && endedAt == nil`. Session `state` is unchanged.
    5. `restoreSession` still restores an ended record when the host asks. The marker only informs.
    6. A new `sessionEnded` directory event is NOT added in this card. Add it only if a consumer asks.

    Tests (`SessionEndedMarkerTests`): set and read back after reload; idempotence and first reason kept; live and recorded paths; listing shows the marker; orderly close with a working run does not mark; old record without marker.
  timestamp: 2026-11-03T13:38:41.284360+00:00
- actor: claude-code
  id: 01m6gxqe954k8060wvxp54j1s2
  text: 'Implemented. Deviation from the DESIGN: SessionSummary belongs to the FoundationModelsExtras package, a git dependency, so Router cannot add endedAt and endReason to it. Router has these public calls instead: markEnded(_:reason:) returns the new SessionEndedMarker; endMarker(of:) reads it; unendedChildren(of:) lists the subagent children that are not ended. The name SessionEnd was taken by a hook event, so the type is SessionEndedMarker. Undecided: whether Extras should get the two summary fields. Full swift test passed.'
  timestamp: 2026-11-03T14:41:33.989585+00:00
position_column: review
position_ordinal: '80'
title: Mark a session record as ended, so a host can tell a finished sub-agent run from an interrupted one
---
## What
A finished sub-agent run has nothing to restore (user, 2026-11-03: "if an agent session is done, there is nothing to restore"). But today a finished child and an interrupted child both exist on disk and nothing marks which is which. (Finding of the Agents session, read in the code: `RoutedSessionActor.close()` in `Session/RoutedSessionActorClosing.swift` lines 128 to 175 unregisters the session from the live directory and closes the output, mail records and cache. It deletes no recording. `SessionRecord` (`Recording/SessionRecord.swift`) has no "ended" field. The transcript tree is loaded from disk.) So after a crash, a host that lists the recorded children of a parent cannot tell the finished ones from the interrupted ones. The user decision: MARK THE RECORD AS ENDED. The recording stays, for history and debugging.

Do (design first; write the design in a task comment and discuss it with the user before the code):
1. Add an ended marker to the session record, such as `endedAt` (and an optional short reason: finished, failed, cancelled) in the `index.md` front matter that `SessionRecord` already uses. It is durable: written before the host reports the run as done.
2. A public call to set it, for the host that owns the run lifecycle (FoundationModelsAgents calls it when an agent run reaches a terminal state). Do NOT set it inside `close()` blindly: a session that closes because the whole process shuts down while runs are working is not a finished run, and its work should still be restorable. Decide who sets it (the host call), and what an orderly shutdown does to the runs that were working (their runs get a terminal journal event from the run plane sweep today; check that this does not conflict with the marker).
3. Expose the marker in the recorded session listing (`Directory/RecordedSessions.swift`, `SessionSummary`) so a host can list the children of a parent (`kind: .subagent`, `parentID`) and skip the ended ones.
4. A restore of an ended session is still possible if the host asks for it (for a read of history); the marker only lets a host choose.
5. No migration for old records (ARCHITECTURE.md rule: no backward compatibility). A record with no marker counts as not ended.
6. Pair with the two other Router needs of the Agents restore (not part of this card, not yet decided): a public lookup of recorded children by `agentSpawn.parentToolCallId` plus a public orphan scan that does not need the restore of the parent; and restore parameters for `parentCall`, the compaction settings and `mailOnlyAnswerLimit`.

Consumer: FoundationModelsACPAgent board, tag `subagents`, task "Cold resume" (`01M6GJPPXWKQJ9E6SK5WD0CWZ7`); FoundationModelsAgents board, card `01M6GNHC0MV9FBT33Z9DTT5TVA` (restore of an interrupted run).

## Acceptance Criteria
- [ ] `SessionRecord` has a durable ended marker, written to the recording.
- [ ] A public host call sets the marker; setting it twice changes nothing.
- [ ] The recorded session listing shows the marker, and a host can list the unended children of a parent.
- [ ] A session that is closed by an orderly shutdown while its run is working is NOT marked ended.
- [ ] A record with no marker counts as not ended; no migration code.
- [ ] No change in the behavior of a session whose host never sets the marker.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SessionEndedMarkerTests.swift`: set and read back after a reload, idempotence, listing, shutdown does not mark, old record.
- [ ] Run `swift test --filter SessionEndedMarkerTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents