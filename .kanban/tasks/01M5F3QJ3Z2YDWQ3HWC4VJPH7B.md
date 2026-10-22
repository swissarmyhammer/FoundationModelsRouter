---
assignees:
- claude-code
comments:
- actor: wballard
  id: 01m5j2y2kkff2g03caabb6zzr0
  text: 'Waits on ^2cqepsd (user decision 2026-10-22): index.md replaces session.json and facts.json. Where this card says facts.json, write the facts into the session''s index.md frontmatter instead (through the ^2cqepsd save path, best-effort and atomic).'
  timestamp: 2026-10-22T15:16:06.899148+00:00
- actor: claude-code
  id: 01m5j7qgvx82a3z72q8s4fk7xw
  text: |-
    ### gap from ^6kq5bqd (ROUTER-5 delivery rules)
    - `send` refuses an archived target through the resolver (`SessionAddressResolution.archivedReason`) and never calls the launcher for it. Today the archived state comes from `facts.json` `archivedAt` for a recorded session (RecordedSessions), and for a live session only from `SessionStateTracking.archive()`, which nothing calls yet.
    - So a live session whose facts hold `archivedAt` still reports its tracked state and a send to it is delivered. `archive(_:by:)` must call the entry's `tracking.archive()` (or take the session off the live list), and carry `archivedAt` onto index.md (^2cqepsd), so the refusal covers each archived session.
  timestamp: 2026-10-22T16:39:55.005146+00:00
- actor: claude-code
  id: 01m5jp7pcyb67bw4azshb4tsm9
  text: |-
    ### research
    - `archive(_:by:)` in RouterSessionDirectory.swift is a provisional body that throws `unknownSession`. `changeRecord(of:_:)` has a recorded branch (read index.md, change, save, emit) that the recorded archive can share; the live branch (`changeLiveRecord`) sends factsChanged, which archive must not send, so the live archive calls `RoutedSessionActor.updateRecord(_:)` itself.
    - Live summaries take their state from `entry.tracking.state` only, so a live session whose record holds `archivedAt` reads as idle/working and the resolver delivers to it (the ^6kq5bqd gap). Fix: the live summary reads `archived` when the facts hold `archivedAt`; the archive also calls `tracking.archive()`.
    - `cancelAll()` is a signal; its `signalDone` comes after the `answerFailed(cancelled)` of the running answer, and the output hub keeps terminals after `close()`, so a test can read the turn's end after the archive. A self-archive from inside the session's own submission cannot await the signal (`waitInsideOpenSubmission`), so the wait is best effort.
    - The directory of a test router has no recording roots unless `useRecordingRoots` is called, so a second archive of a formerly-live session needs roots to find it on disk.
    - Audit: no log metadata key for the archiver exists; add `RouterTelemetry.LogMetadataKey.archivedBy` (an identifier) and list it in `allKeys`.
  timestamp: 2026-10-22T20:53:25.022858+00:00
- actor: claude-code
  id: 01m5jpnm8ts1myg7szkahgmpvf
  text: |-
    ### implementation landed
    - `archive(_:by:)` in RouterSessionDirectory.swift: live path `archiveLive` = `cancelAll()`, then `updateRecord { archivedAt }` with no suspension between them (so a concurrent send is refused as archived, and a concurrent second archive returns at the guard), then a best-effort wait for the cancel signal's end, then `takeArchived` (entry off the live list under the lock, feed cancelled, `tracking.archive()`), then `close()`, then events. Recorded path `archiveRecorded` shares the new `changeRecordedRecord(of:_:)` with `changeRecord(of:_:)`. archivedAt goes to index.md (not facts.json), rounded to milliseconds.
    - Events: the directory sends `stateChanged(id, .archived, nil)` then `archived(id:)` (ROUTER-9 says each state change sends stateChanged); `next(through:)` filters the stateChanged, so the tests see exactly one `archived`.
    - Gap from ^6kq5bqd closed: the live summary reads `archived` when the facts hold `archivedAt`, so `send` refuses it.
    - Audit: notice log "a session was archived" with `sessionId` and the new `LogMetadataKey.archivedBy` (in `allKeys`).
    - Held unread messages: `cancelAll()` drops the waiting mail (the test sees `cancelled(id)` and no second prompt); the ledger record stays.
    - Test helper: `SessionDirectoryRouterPair.make(prefix:recordingContainer:)` takes the container of the recording router (default basic).

    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Tracing/RouterTelemetry.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift (new, 11 tests), Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryRouterPair.swift, this card. `swift build --build-tests` clean; `swift test --filter RouterSessionDirectoryArchive` 11/11 (10 red first for the missing feature); full `swift test` 2154 tests in 263 suites passed (9 known issues are the pre-existing helper self-tests).
    - next: /review
  timestamp: 2026-10-22T21:01:01.594518+00:00
- actor: claude-code
  id: 01m5jpydyk0fvxy71r6vmycxje
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (5090cc40) — 0 findings, 0 confirmed, 0 refuted; 7 validator runs attempted, 0 failed; 4 files reviewed, 2 .kanban files excluded by .reviewignore. No prior Review Findings sections.
    - next: done
  timestamp: 2026-10-22T21:05:50.035528+00:00
- actor: wballard
  id: 01m5jpytantttrkky3fncdh03x
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — archive(_:by:) for live and recorded sessions; a live archived session refuses send
    - test: green per implementer — swift test 2154 passed, 9 known issues
    - commit: 5090cc40
    - review: clean — 0 findings; card in done
  timestamp: 2026-10-22T21:06:02.709863+00:00
depends_on:
- 01M5F3HHXA8XHWQWDZJ2CC8D3F
- 01M5F3PESH74WZB1EDN6KQ5BQD
- 01M5F3KKY94S2A8N8JCBN9FC99
- 01M5F43CQ0KR0A2E8FA8CAT9XK
- 01M5HS4PZCZH6W43MM72CQEPSD
position_column: done
position_ordinal: ffffffffbc80
title: 'ROUTER-11: archive(_:by:) stops the turn, leaves the live list, writes archivedAt, and sends archived'
---
## Goal
`RouterSessionDirectory.archive(_:by:)` ends a session (D68, D72): it stops a running turn, removes the session from the live list, writes `archivedAt` to `facts.json`, and sends `archived(id:)`. An archived session takes no message and is never restored.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-11-archive-a-session
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.8
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 6 (`archive`), 13.3

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, replace the provisional `archive`:
  - Unknown id: throws `unknownSession(id)`.
  - Already archived (live state or `facts.archivedAt` on disk): gives its summary again and sends no event.
  - Live session: `cancelAll()` (`Session/RoutedSession.swift`; stops a running turn as a cancel does), then `updateFacts { $0.archivedAt = now }` (ROUTER-1), then `close()` and unregister, then the state reducer's `archived` (ROUTER-9), then `archived(id:)`. Held unread messages of the session (ROUTER-5 ledger) are dropped, not mailed.
  - Recorded, not live: write `archivedAt` into its `facts.json` on disk; send `archived(id:)`. Never call the launcher.
  - `by` is the session or the user that archives: write it to the log with the session id (the audit); it is not a stored fact in ROUTER-1. There is no built-in limit; only a deny rule in the `runCode` risk check (MT-1, Multitool) can stop a model call.
- The archived refusal in `send` already comes from the resolver and the delivery card; this card adds the tests that prove it after an archive and after a restart.

## Subtasks
- [x] Failing test first: archive a working session (a scripted model that waits); its turn ends cancelled, it is gone from the live query, and an events stream gets `archived(id:)`.
- [x] Implement the live path, with `archivedAt` in `facts.json` and the held messages dropped.
- [x] Implement the recorded path and the idempotent second call (no second event).
- [x] After a restart (a new router on the same roots): the session is found only with `includesRecorded`, its state is `archived`, and `facts.json` has `archivedAt`.
- [x] A send to it gives `refused` with the reason "archived", and the fake launcher's `restoreSession` is never called.

## Acceptance Criteria
- [x] Archive of a working session stops its turn, removes it from the live list, writes `archivedAt`, and sends one `archived` event.
- [x] A second archive gives the summary and sends no event.
- [x] After a restart, the session is `archived` and appears only with `includesRecorded`.
- [x] A later send is refused with the reason "archived", and the launcher is not called.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift`
- [x] `swift test --filter RouterSessionDirectoryArchive` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #router-api