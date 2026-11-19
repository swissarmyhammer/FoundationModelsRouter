---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7shh91p4467h531z04z5080
  text: |-
    Unblocked: Extras D206 is on origin/main at f99b111 (code commit e8212b9), from foundationmodelsextras-9e on 2026-11-19.
    - `SessionSummary.recap: String?` and `SessionSummary.recapAt: Date?`, both default nil in the initializer (trailing arguments after `archivedAt`); Codable, old JSON decodes as nil.
    - No new event: a new recap goes out as `factsChanged`. `lastSummary` and `stateChanged` do not change.
    - Extras has no `SessionFacts` and no index.md: the record facts are the Router's.
    - No new public enum cases; no API break.
    - `InMemorySessionDirectory` has the test hook `setRecap(of:_:at:)`; an archive and an unarchive keep the recap (match this).
    Update the pin after ^h3xtekz ends, with `swift package --manifest-cache local update FoundationModelsExtras`.
  timestamp: 2026-11-19T09:17:20.822611+00:00
- actor: claude-code
  id: 01m7sj612j3wh3a82z693xz3dr
  text: |-
    Research (implement):
    - Package.resolved already pins FoundationModelsExtras at f99b111; no `swift package update` is necessary.
    - `SessionFacts.forFork` copies only agentID, agentName and origin, so a fork gets no recap and no lastSummary when the new fields are added. The test is a guard: it passes before the change, and it fails if forFork copies the facts.
    - `RouterSessionDirectory.changeRecord(of:_:)` already writes a live record (`RoutedSessionActor.updateRecord`) or a recorded `index.md`, and sends `factsChanged` only when the record changed. The recap write uses it.
    - `recordState(after:of:)` sends `stateChanged(idle)` under the registry lock. The lastSummary write must occur BEFORE that send, so a reader that waits for idle finds it on disk. Plan: at `workEnded`, write the tracked lastSummary to the facts first (no registry lock held during the record lock), then apply the event.
    - A live session that a restore made starts with an empty tracking, so the live summary gives `tracking.lastSummary ?? facts.lastSummary`.
    - `recordedFolder(of:)` finds only a folder directly under a root, so a recorded fork that is not live is not found by `changeRecord`. This limit is not new.
  timestamp: 2026-11-19T09:28:40.786904+00:00
- actor: claude-code
  id: 01m7sjmx5sf0kvgzvw14jk45bf
  text: |-
    Implementation landed.
    - What did not work: the first design wrote `lastSummary` from the directory feed task at `workEnded`. That write comes AFTER `respond` returns, so it rewrote `index.md` over a later edit of the file. 6 tests failed in the full run: DecisionRecordingTests, ModelSwitchRestoreTests, and 4 SessionTreeRestorationTests (a test edits the `index.md` after a turn, and the late feed write replaced the edit). Do not move the write back to the directory.
    - Final design: the session writes the last summary itself, in `emitAnswerEnd(for:)`, before it sends `answered` (`RoutedSessionActor.recordLastSummary(of:)`). It writes only when the facts hold another value. `SessionStateTracking.lastSummary(of:)` is the one cut (500 characters) for the tracking and the record. The live summary gives `tracking.lastSummary ?? facts.lastSummary`, so a restored session gives the summary of its record.
    - Internal write API for ^4maqy3m: `RouterSessionDirectory.recordRecap(_:at:of:)`. It writes `recap` and `recapAt` (rounded to the millisecond) through `changeRecord(of:_:)`, sends `factsChanged` only on a change, and reaches a live session and a recorded one that is not live (also when archived). Limit (not new): `recordedFolder(of:)` does not find a recorded fork that is not live, because its folder is nested in its source folder.
    - Guard tests that passed before the change, as expected: `aRecordWithNoRecapKeysReadsThemAsNil` (fails if decode requires the keys) and `theForkHasNoRecapAndNoLastSummaryOfItsSource` (fails if `forFork` copies the facts).
  timestamp: 2026-11-19T09:36:48.313852+00:00
- actor: claude-code
  id: 01m7sjn2xwwg1zp92haj1r5bsf
  text: |-
    ### implement — changed
    - evidence: Sources: Recording/SessionFacts.swift, Recording/SessionRecord.swift, Directory/RecordedSessions.swift, Directory/RouterSessionDirectory.swift (`recordRecap(_:at:of:)`, live summary, type doc), Directory/SessionStateTracking.swift (`lastSummary(of:)`, type doc), Session/RoutedSessionActorIndex.swift (`recordLastSummary(of:)`), Session/RoutedSessionActorSubmissionEvents.swift. Tests: new RouterSessionDirectoryRecapRecordTests (13), SessionIndexFileTests (+2, full record has the new fields), RouterSessionDirectoryForkTests (+1). RED seen: 11 issues in phase 1 (runtime), compile error `no member recordRecap` in phase 2. Changed suites: 140 tests in 8 suites passed. Full `swift test` (one run after the fix): 3120 tests in 354 suites passed, plus 50 and 19; no warnings. Output: scratchpad/full-suite-2.txt.
    - next: /review
  timestamp: 2026-11-19T09:36:54.204858+00:00
depends_on:
- 01M7S16CT48HZ95JXCKH3XTEKZ
position_column: doing
position_ordinal: '80'
title: The record keeps lastSummary, recap and recapAt, and each summary gives them (D206)
---
## Goal

The session facts keep the last summary (ROUTER-9) and the recap (D206), so a recorded session gives them after a restart. Decision D206 (`TestudoApp/features/decisions.md`, commit da60a90). Brief: `../.briefs/recap/router-brief.md` items 1, 4 and 6; overview `overview.md`.

## Depends on

FoundationModelsExtras: `SessionSummary.recap` and `recapAt`. Do not start before Extras sends the D206 sha. Update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo). The dependency on ^h3xtekz is only the order of work.

## Current behavior

- `SessionStateTracking` keeps the last final reply cut to 500 characters, in memory only (`Sources/FoundationModelsRouter/Directory/SessionStateTracking.swift:41`, `:90`).
- `recordState(after:of:)` (`Directory/RouterSessionDirectory.swift:3644-3660`); the live summary gives `lastSummary` (`:700-722`, `:718`).
- `SessionFacts` has no summary (`Recording/SessionFacts.swift:16-46`); keys `Recording/SessionRecord.swift:266`, decode `:318`, encode `:365`.
- A recorded session gives no last summary (`Directory/RecordedSessions.swift:123-141`).

## Change

- Add `lastSummary`, `recap` and `recapAt` to `SessionFacts`, with coding keys in the record. A missing key decodes as `nil`.
- Write `lastSummary` with the record at the end of each turn that changed it.
- `RecordedSessions.summary(of:)` and the live summary give all three (`SessionSummary.lastSummary`, `.recap`, `.recapAt`).
- A fork starts with no `recap` and no `lastSummary` (the fork facts copy neither).
- Update the type doc of `SessionStateTracking` and of the directory (ROUTER-9) to name D206.

## Tests

- [x] A turn writes `lastSummary` to the record; a restart gives it in the recorded summary.
- [x] `recap` and `recapAt` written to the facts are in the live and the recorded summary, and after a restart.
- [x] An old record with no such keys decodes, with `nil`.
- [x] A fork has no `recap` and no `lastSummary`.

## After

Push when green. Send the sha to foundationmodelsmultitool-89, foundationmodelsacpagent-9e and testudoapp-9a. #d206