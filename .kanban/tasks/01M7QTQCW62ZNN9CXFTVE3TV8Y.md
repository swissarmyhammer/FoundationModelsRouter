---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qts8m3sk9kzye31kn4stq3
  text: |-
    Addition from TestudoApp (testudoapp-9a): Extras adds `SessionSummary.archivedAt: Date?`. The Router sets it in each summary (live and recorded) from the `archivedAt` that the record already holds (`Recording/SessionFacts.swift:35-37`, coded in `Recording/SessionRecord.swift`), so it survives a restart. Unarchive clears it. The app sorts the Archived section by it.
    Add tests:
    - [ ] After an archive, the live and the recorded summary have `archivedAt` equal to the time of the archive, also after a restart (a new directory reads the record).
    - [ ] After an unarchive, `archivedAt` is nil.
  timestamp: 2026-11-18T17:20:30.851504+00:00
- actor: claude-code
  id: 01m7qv84py6hk1cj4y8evr612q
  text: 'Heads-up from TestudoApp: Extras 1b2f9f3 adds `unarchive(_:by:)` to the `SessionDirectory` protocol with NO default. `RouterSessionDirectory` does not compile against it until this task implements it. The Router follows the `main` branch of Extras, so the Router CI breaks when Extras pushes, until this task is pushed. Do this task first when the Extras sha comes. The event is `SessionDirectoryEvent.unarchived(id:)`. `SessionSummary.archivedAt` is in the same commit.'
  timestamp: 2026-11-18T17:28:38.366432+00:00
- actor: claude-code
  id: 01m7qvymc9cc2kvr61qmga5944
  text: |-
    Implementation notes (implement step):
    - Extras was at 4c521cb in Package.resolved already. Without `unarchive(_:by:)` the Router did not compile. The one exhaustive `switch` on `SessionDirectoryEvent` was in `Tests/.../RouterSessionDirectoryQueuedEventTests.swift` (`messageEvent(of:)`). It now has `.unarchived`. IntegrationTests and Tools have no such switch.
    - `RouterSessionDirectory.unarchive(_:by:)`: a recorded session uses `changeRecordedRecord` (`archivedAt = nil`). A live session uses `updateRecord` and then `takeUnarchived` (`SessionStateTracking.unarchive()` under the registry lock). `sendUnarchived` sends `stateChanged` (with the state of the summary; the last summary only with idle), then `unarchived`, and logs `unarchivedBy` (new `RouterTelemetry.LogMetadataKey.unarchivedBy`). A session that is not archived gives its summary with no write and no event. A live session stays live.
    - Decision: `SessionStateTracking.unarchive()` changes only an archived tracking (state idle, hasWork and open questions cleared). A tracking that is not archived keeps its state. The tracking of a live entry is never archived in practice (`takeArchived` removes the entry). Thus a live session loaded while archived reads its real work state after the unarchive (idle when no turn runs) and is never set to idle while a turn runs.
    - `SessionSummary.archivedAt` comes from `facts.archivedAt` in the live summary and in `RecordedSessions.summary(of:)`.
    - No factsChanged is sent on an unarchive, the same as on an archive.
    - Test fixture change: `RouterSessionDirectoryArchiveTests.makeFixture()` is no longer private, so the new suite uses it.
    - No existing test failed. The archive still drops waiting mail and a send to an archived session is still refused: those are ^2b3p9bs and ^gw486td.
  timestamp: 2026-11-18T17:40:55.305730+00:00
- actor: claude-code
  id: 01m7qvysbpbycpg96vstkyb177
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Directory/SessionStateTracking.swift, Directory/RecordedSessions.swift, Tracing/RouterTelemetry.swift; Tests/FoundationModelsRouterTests/RouterSessionDirectoryUnarchiveTests.swift (new, 15 tests), SessionStateTrackingTests.swift (+3 tests), RouterSessionDirectoryArchiveTests.swift (makeFixture not private), RouterSessionDirectoryQueuedEventTests.swift (.unarchived case). New tests RED with a stub, then GREEN (18 of 18). Full `swift test`: 2945 tests in 341 suites, 49 in 26, 19 in 3, all passed; build has no warnings.
    - next: /review
  timestamp: 2026-11-18T17:41:00.406006+00:00
- actor: claude-code
  id: 01m7qw92q602w95kes32mp5n9e
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (18bbe4da); 2 findings (2 confirmed, 3 refuted) — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2987, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:3008
    - next: implement the two reuse/reuse findings in a follow-up commit, then review again.
  timestamp: 2026-11-18T17:46:37.670271+00:00
- actor: claude-code
  id: 01m7qw9vm6kp67htczf59qcvsf
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionStateTracking.swift, RecordedSessions.swift, RouterTelemetry.swift, 4 test files
    - test: green — swift test in the implement step, 2945 tests in 341 suites (+49, +19), 0 failures
    - commit: 18bbe4da (pushed before the review, because the Router did not compile against Extras 4c521cb and the Multitool CI was red)
    - review: findings — RouterSessionDirectory.swift:2987 (takeUnarchived copies takeArchived), RouterSessionDirectory.swift:3008 (sendUnarchived copies sendArchived)
  timestamp: 2026-11-18T17:47:03.174081+00:00
- actor: claude-code
  id: 01m7qwm0gjfn3x5ax27pak6b7r
  text: |-
    Review findings fixed in RouterSessionDirectory.swift. No behavior change.
    - New private helper `changeLiveEntry(of:_:announcing:)`. In one hold of the lock, it finds the entry and the session, applies the change closure (inout Registry, inout Entry), stamps `updatedAt`, puts the entry back only when the change did not remove it, makes the summary (`isLive` is false when the change removed the entry), and gives the summary to `announce` under the same lock.
    - `takeArchived` and `takeUnarchived` call it. The closure of `takeArchived` removes the entry, cancels the feeds, forgets the deliveries and archives the tracking. The closure of `takeUnarchived` unarchives the tracking.
    - Same cause in the file: `recordFactsChange(of:)` had the same lock, lookup, timestamp and summary steps. It now calls the helper with `announcing:` to send `factsChanged` under the lock, and `try?` keeps "no live session changes nothing".
    - New private helper `sendArchiveChange(of:state:lastSummary:event:log:actorKey:actor:)` sends `stateChanged`, then the event, then the audit log line. `sendArchived` and `sendUnarchived` call it.
    - Note: the old `takeArchived` removed an entry whose weak session was nil before it threw `unknownSession`. The helper throws and does not remove it. The caller (`archiveLive`) holds a strong reference to the session, so that path cannot occur.
    - Discovery: a single unlabeled trailing closure binds to the first closure parameter (`change`), so `recordFactsChange` must use the label `announcing:`.
  timestamp: 2026-11-18T17:52:35.858934+00:00
- actor: claude-code
  id: 01m7qwm2x2c4jbr6zfx1xecacz
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift (changeLiveEntry, sendArchiveChange; takeArchived, takeUnarchived, recordFactsChange, sendArchived, sendUnarchived use them). `swift build` has no warnings from the source. Full `swift test` one time with Extras at ec528ec: 2945 tests in 341 suites, 49 in 26, 19 in 3, all passed, exit 0. Both review findings are `- [x]`.
    - next: /review
  timestamp: 2026-11-18T17:52:38.306739+00:00
position_column: doing
position_ordinal: '80'
title: Unarchive a session in RouterSessionDirectory (D204)
---
## Goal

`RouterSessionDirectory` implements `unarchive(_:by:)`. An unarchived session is a recorded session until a client opens it. Decision D204 (`TestudoApp/features/decisions.md`, commit 9281f9c). Brief: `../.briefs/archive/router-brief.md`, items 1, 4 and 5; overview `overview.md`.

## Depends on

FoundationModelsExtras (`extras-brief.md`): the protocol operation `unarchive(_:by:)` on `SessionDirectory` and the event `SessionDirectoryEvent.unarchived`. Do not start before Extras sends the sha. Then update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo).

## Current behavior

- `archive(_:by:)` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2763-2768`) archives a live session (`archiveLive`, `:2794-2808`) or a recorded session (`archiveRecorded`, `:2820-2828`). The doc says that the directory "never restores it" (`:2734-2737`).
- `sendArchived` sends `stateChanged` with `archived`, then `archived`, and logs `archivedBy` (`:2885-2891`, `Tracing/RouterTelemetry.swift:480-483`).
- The record holds `archivedAt` (`Recording/SessionFacts.swift:35-37`, `Recording/SessionRecord.swift:266`, `:318`, `:365`). Summaries read `archived` from it (`Directory/RecordedSessions.swift:109`, `RouterSessionDirectory.swift:599`).
- `SessionStateTracking.archive()` sets the state to `archived`, and a later event does not change it (`Directory/SessionStateTracking.swift:71`, `:114`).

## Change

- A recorded session that is not live: remove `archivedAt` from its `index.md` with `changeRecordedRecord(of:_:)`.
- A live session whose record holds `archivedAt` (a client opened it with `session/load`): remove `archivedAt` with `updateRecord`, and set the tracked state back to `idle` (add the inverse of `SessionStateTracking.archive()`).
- Then send `stateChanged` with `idle`, then `unarchived`, and log the audit line with the new key `unarchivedBy`.
- A session that is not archived: give its summary, send no event, write nothing.
- Unknown id: `SessionDirectoryError.unknownSession`. No limit on an unarchive, the same as on an archive.
- Change the doc of `archive(_:by:)` and the type doc (`:73-76`, `:2734-2737`): an archive hides the session and is not final (D204).
- Keep `SessionDefaultTitle` as it is.

## Tests

- [x] Recorded session: archive, then unarchive. `index.md` has no `archivedAt`; the summary is `idle` and not live; the events are `stateChanged(idle)` then `unarchived`; the log has `unarchivedBy`.
- [x] Live session opened while archived: unarchive removes `archivedAt`, the state is `idle`, and the same events come.
- [x] Unarchive of a session that is not archived: no event, no write.
- [x] Unknown id: `unknownSession`.
- [x] An unarchived recorded session with inbox files: when a client opens it, it reads its inbox (D199 (f)).
- [x] (comment addition) After an archive, the live and the recorded summary have `archivedAt` equal to the time of the archive, also after a restart.
- [x] (comment addition) After an unarchive, `archivedAt` is nil.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d204

## Review Findings (2026-11-18 11:41)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 16 not reviewed.

> 16 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 16 file(s)

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2987` `reuse/reuse` — takeUnarchived repeats the lock, lookup, timestamp and summary skeleton of takeArchived. The two functions differ only in whether the registry entry is removed and whether feeds are cancelled. Keeping two copies of the skeleton risks the lookup or the summary building diverging. Extract the shared lookup, tracking change, timestamp and summary steps into one private helper that takes the tracking change as a closure. takeArchived keeps its removeValue and cancelFeeds steps, and takeUnarchived keeps its own. Alternatively, accept the duplication and note why the two differ.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:3008` `reuse/reuse` — sendUnarchived repeats the shape of sendArchived. Both emit stateChanged, then a session event, then write an audit log line with a metadata key for the actor. Only the state value, the lastSummary rule, the event case and the log key differ. A second copy of the emit and log sequence can drift from the first. Extend sendArchived into one private helper that takes the state, the lastSummary value, the event and the log message and metadata key as parameters. Call it from both sendArchived and sendUnarchived.
