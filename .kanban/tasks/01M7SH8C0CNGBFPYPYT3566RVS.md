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
- actor: claude-code
  id: 01m7sjxfyx1zc8r3mz66y5xhp9
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (bd250758): engine 2 findings (2 confirmed, 1 refuted) — Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecapRecordTests.swift:118, Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecapRecordTests.swift:321; driver check 1 finding — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2742 (recordRecap cannot find a recorded fork that is not live, and its doc says it can).
    - other checks, no finding: `recordLastSummary(of:)` in `emitAnswerEnd(for:)` is synchronous and adds no suspension point. Its file write is under the record lock, as `recordSubmissionStart()` already does on the same path. A directory change of a live record goes through `updateRecord(_:)` in place, so it cannot write over `lastSummary` with an old copy. An old record with no keys decodes (`decodeIfPresent`, test `aRecordWithNoRecapKeysReadsThemAsNil`). The two guard tests hold real behavior: the decode test fails if the decode requires the keys; the fork test fails if `forFork` copies the facts.
    - next: /implement the three items in the Review Findings section.
  timestamp: 2026-11-19T09:41:29.693827+00:00
- actor: claude-code
  id: 01m7sjy4yq4prtz1rfpfavnfxe
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionFacts.swift, SessionRecord.swift, RecordedSessions.swift, RouterSessionDirectory.swift, SessionStateTracking.swift, RoutedSessionActorIndex.swift, RoutedSessionActorSubmissionEvents.swift; RouterSessionDirectoryRecapRecordTests (new, 13), SessionIndexFileTests (+2), RouterSessionDirectoryForkTests (+1)
    - test: green — one full swift test run, 3120 tests in 354 suites (+50, +19), 0 failures
    - commit: bd250758
    - review: findings — RouterSessionDirectoryRecapRecordTests.swift:118 (copied helper), :321 (recapAt not read back), RouterSessionDirectory.swift:2742 (changeRecord cannot find a recorded fork that is not live)

    Orchestrator decision for :2742: FIX it. `recordedFolder(of:)` (or the lookup that `changeRecord(of:_:)` uses) must find a recorded fork at any depth, the same way `RecordedSessions` lists it since ^3hxcxee. Then `recordRecap`, archive and unarchive work for a recorded fork that is not live. Add tests for recordRecap, archive and unarchive of such a fork.
  timestamp: 2026-11-19T09:41:51.191595+00:00
- actor: claude-code
  id: 01m7sk6yh4x9hyvx0ts0p5xs8q
  text: |-
    Review findings fixed (implement, iteration 2):
    - Item 1 (:118): `SessionRecordFixtures.recordOnDisk(in:)` (Helpers/SessionRecordFixtures.swift) is the one shared read of an `index.md`. Four suites had a private copy: RecapRecord and Archive (`recordOnDisk(of:)`), Tag and Unarchive (`recordOnDisk(in:)`). All four copies are removed, and the four suites use the shared helper. The direct `#require(SessionIndexFile.read(...))` reads in the Archive suite and in one Fork test use it too.
    - Item 2 (:321): the recorded-session recap write test also checks `recapAt`.
    - Item 3 (:2742, FIX): `RecordedSessions.listedEntry(of:)` gives the entry of `listedEntries()` for an id (a root session, or a recorded fork at any depth). It reuses the listing code of ^3hxcxee. The new `RouterSessionDirectory.listedRecordedFolder(of:)` tries `recordedFolder(of:)` (direct folder, fast) first, and then `listedEntry(of:)`. `changeRecordedRecord(of:_:)` uses it, so `recordRecap`, archive, unarchive, tags, title and additional directories all reach a recorded fork that is not live.
    - Not changed, on purpose: the other callers of `recordedFolder(of:)` (`usageTarget`, `inboxFolder`, `knownLedger`, `endMarker`). `usageTarget` takes the parent folder of the result as the recording root. For a nested fork, that parent is the source folder and not a root, so a global change of `recordedFolder(of:)` would give a wrong root there.
    - RED: the 3 new tests in RouterSessionDirectoryForkTests (`aRecapWriteReachesARecordedForkAfterARestart`, `anArchiveReachesARecordedForkAfterARestart`, `anUnarchiveReachesARecordedForkAfterARestart`) each failed with `Caught error: .unknownSession(...)` before the fix. GREEN after the fix: 3 tests in 1 suite passed.
  timestamp: 2026-11-19T09:46:39.524491+00:00
- actor: claude-code
  id: 01m7sk72ay097xt1q6p5dr8ssg
  text: |-
    ### implement — changed
    - evidence: Sources: Directory/RecordedSessions.swift (`listedEntry(of:)`), Directory/RouterSessionDirectory.swift (`listedRecordedFolder(of:)`, used by `changeRecordedRecord(of:_:)`; docs of `changeRecord`, `changeRecordedRecord`, `recordRecap`). Tests: Helpers/SessionRecordFixtures.swift (shared `recordOnDisk(in:)`), RouterSessionDirectoryRecapRecordTests (recapAt check, shared helper), RouterSessionDirectoryArchiveTests, RouterSessionDirectoryUnarchiveTests, RouterSessionDirectoryTagTests (shared helper), RouterSessionDirectoryForkTests (+3 recorded-fork tests, `restartAfterAFork(of:archivesTheFork:)`). RED: 3 new tests failed with `.unknownSession`. Changed suites: 122 tests in 7 suites passed. Full `swift test` (one run): 3123 tests in 354 suites passed, plus 50 and 19; no warnings. Output: scratchpad/full-suite-3.txt.
    - next: /review
  timestamp: 2026-11-19T09:46:43.422544+00:00
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

## Review Findings (2026-11-19 03:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 10 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecapRecordTests.swift:118` `reuse/reuse` — The new helper recordOnDisk(of:) reimplements an existing helper with the same body. The same one-line read of the session index is already in RouterSessionDirectoryArchiveTests, so the same logic now lives in two places and can drift apart. Move recordOnDisk into a shared test helper (for example, beside SessionDirectoryRouterPair in Tests/FoundationModelsRouterTests/Helpers/) and call it from both suites. Or make the existing helper internal rather than private and call it from the new suite. Do not keep two copies.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryRecapRecordTests.swift:321` `completeness/inverse-operation-coverage` — The recorded-session recap write test reads back only the recap from the index.md. It does not check recapAt. The sibling live-session test (aRecapWriteOfALiveSessionWritesTheRecord, lines 253-254) checks both recap and recapAt. A recap write to a recorded session could store the text and drop or corrupt the time, and this test would still pass. Add `#expect(record.facts.recapAt == Self.recapAt)` after line 321 so the recorded-session write is checked for both fields, as the live-session write already is.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2742` `review/driver-check` — The doc of `recordRecap(_:at:of:)` says that "a live session and a recorded session that is not live, also an archived one, take the recap alike", and that it throws `unknownSession` only "when no live or recorded session has the id". This is not true for a recorded fork that is not live. `changeRecord(of:_:)` finds a recorded session with `recordedFolder(of:)`, which looks only at `<root>/<id>`. A recorded fork has its folder inside the folder of its source, and `RecordedSessions.listedEntries()` lists it (^3hxcxee). Thus the directory lists the fork, and `recordRecap` on it throws `unknownSession`. This has an effect on ^4maqy3m: the recap maker makes a recap 20 s after a turn, and a fork that closes in that time loses its recap with no error to the user. Make `recordRecap` reach a recorded fork that is not live (find the folder at any depth, as `nestedEntries()` does), and add a test that writes a recap to a closed fork and reads it from its `index.md`. If the limit stays, state it in the doc and in the `- Throws:` part, and add a test that shows the `unknownSession` error for a closed fork.
