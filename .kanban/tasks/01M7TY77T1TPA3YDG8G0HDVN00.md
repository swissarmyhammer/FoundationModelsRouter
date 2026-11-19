---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7tykr3am309300g6pphe01m
  text: |-
    Unblocked: Extras D209 is on origin/main at 4f3afb5 (code commit f3e7cfe), from foundationmodelsextras-9e on 2026-11-19.
    - `SessionDirectoryOrigin.import` (raw "import"); `SessionImportProvenance` (`agent`, `sourceID`, `sourcePath`, `sourceLastDate: Date?`, `importedAt`, `skippedRecordCount`; Codable); `SessionSummary.importedFrom` (default nil); `SessionImportRequest` (`agentID: String?`, `workingDirectory: URL`, `title: String`, `provenance`, `startedBy: ULID?`).
    - `SessionDirectory.importSession(_ request: SessionImportRequest, transcript: Transcript) async throws -> SessionSummary`, with a default that throws `SessionDirectoryError.importUnsupported` (the Router compiles before this task).
    - Name rule of the in-memory directory: the title as given when its slug is free in the folder, else `<slug>-2`, `-3` (`SessionName.default`). Match it.
    - Orchestrator decision on the event: the Router sends `factsChanged` with the summary of the new imported session (no new event case), so the change feed shows it. Extras aligns its in-memory directory and doc.
    Update the pin after ^mdhq7rh ends, with `swift package --manifest-cache local update FoundationModelsExtras`.
  timestamp: 2026-11-19T22:25:07.690133+00:00
- actor: claude-code
  id: 01m7v0tj3qejwggqg83j2kpxs7
  text: |-
    Research (implement):
    - The directory holds no model. The host makes each session through `SessionLauncher` (`launchRootSession`, `restoreSession`, `forkSession`). Thus the directory gets the model handle of the agent's default through the launcher: a new launcher operation `importTarget(for: SessionImportRequest) -> SessionImportTarget` (the `RoutedLLM` handle of the default of the resolved agent, and the `SessionConfiguration` of the agent). The protocol default throws `SessionDirectoryError.importUnsupported`, so a host launcher still compiles (ACPAgent must implement it).
    - The provenance goes to the writer through a new fact field `SessionConfiguration.importedFrom` (in `initialFacts`), as `origin` does. The directory sets `origin = .import`, `importedFrom`, the title (name), `startedBy` and the folder of the request on the configuration of the launcher.
    - `SessionFacts.importedFrom` is a nested map under the flat key `importedFrom`; its dates are millisecond text like every other date of the record.
    - The live summary (`summary(of:in:usage:)`) also must give `importedFrom`, so a restored import shows it.
    - Name rule: the slugs of the live and recorded sessions in the folder that are not archived, as `SessionDefaultTitle` collects them; the title when its slug is free, else `SessionName.default(agentName: title, usedNames:)` (Extras in-memory rule). A name that an import in flight holds is reserved on the actor, so two imports at the same time do not get the same name.
    - Event: one `factsChanged(summary)` after the write, no `started`.
  timestamp: 2026-11-19T23:03:48.087644+00:00
- actor: claude-code
  id: 01m7v1j321nm7ad2zbs6x04r42
  text: |-
    ### implement — changed
    - evidence: model handle: a new `SessionLauncher.importTarget(for: SessionImportRequest) -> SessionImportTarget` (the `RoutedLLM` of the default of the resolved agent and the configuration of the agent); the protocol default throws `importUnsupported`. The directory sets the folder, name, startedBy, origin `.import` and `importedFrom` (new `SessionConfiguration.importedFrom`, in `initialFacts`) and writes with `recordSession(from:configuration:)`, reads the record back, sends one `factsChanged(summary)`, no `started`. Name rule in `SessionDefaultTitle.makeImport`; `SessionImportNames` holds the names of imports in flight and of ended imports until a summary shows them. `SessionFacts.importedFrom` is the flat key `importedFrom` (`RecordedImportProvenance`, millisecond dates); `SessionSummary(record:)` and the live summary give it.
    - files: Sources: Directory/RouterSessionDirectory.swift, Directory/SessionLauncher.swift, Directory/SessionDefaultTitle.swift, Directory/SessionImportNames.swift (new), Directory/RecordedSessionSummary.swift, Recording/SessionFacts.swift, Recording/SessionRecord.swift, Recording/RecordedImportProvenance.swift (new), Recording/TranscriptSessionWriter.swift (doc), Session/SessionConfiguration.swift. Tests: RouterSessionDirectoryImportTests.swift (new, 19 tests), SessionIndexFileTests (3 new), SessionSummaryRecordTests (1 new), SessionLauncherPublicSurfaceTests (2 new), Helpers/FakeSessionLauncher.swift.
    - RED: compile failure first; then with the API surface only, 19 issues in the 3 suites; the surface import test failed with the directory method hidden. Absence tests (failed write leaves nothing, old index.md reads nil, launcher default) passed before the code because the stub wrote nothing.
    - GREEN: changed suites 69 tests in 5 suites + 5 in 1 suite passed. Full `swift test` once: 3235 tests in 364 suites passed, plus 54 and 19; exit 0; no compiler warnings. Output: scratchpad/full-suite.txt.
    - note: ACPAgent must implement `importTarget(for:)` (default throws `importUnsupported`). Not committed.
    - next: /review
  timestamp: 2026-11-19T23:16:39.105513+00:00
- actor: claude-code
  id: 01m7v228z6dsd3dd1dbw4gsbfh
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` engine counts: 0 findings, 0 confirmed, 0 refuted (14 files). Extra checks gave 3 findings: Sources/FoundationModelsRouter/Directory/SessionImportNames.swift:55 (no test of the held names; a mutation with `reserved: []` kept 18/18 import tests green, file put back, `git status --short` shows only the two `.kanban/` files of this task), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1805 (a held name stays when the recording root of the import is not a root that the directory reads), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1856 (the provenance dates are not rounded at entry; the returned `importedFrom` is not equal to `request.provenance` for a date with a part smaller than one millisecond).
    - checked and correct: the name rule and the used-name set match the Extras in-memory directory (`importName`, `usedNames(in:)`); a failed write releases its name, leaves no folder, no entry and no event; the restore of an import gives origin `import` and `importedFrom`; one `factsChanged` and no `started`; the launcher default throws `importUnsupported`.
    - next: /implement the 3 items, then /review.
  timestamp: 2026-11-19T23:25:29.446396+00:00
- actor: claude-code
  id: 01m7v23p0wg6saewdhb22fa8pn
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionLauncher.swift (importTarget(for:)), SessionDefaultTitle.swift, SessionImportNames.swift (new), RecordedSessionSummary.swift, SessionFacts.swift, SessionRecord.swift, RecordedImportProvenance.swift (new), SessionConfiguration.swift; 5 test files (25 new tests)
    - test: green — one full swift test run, 3235 tests in 364 suites (+54, +19), 0 failures
    - commit: 32c44874
    - review: findings — SessionImportNames.swift:55 (the held names have no test), RouterSessionDirectory.swift:1805 (a held name stays when the launcher's root is not a root the directory reads), :1856 (the provenance dates are not rounded to the millisecond)

    Orchestrator decision for :1805: a held name protects only the time of the write. Release it when importSession ends (success or failure). Make the imported session visible to the list: record its recording root in the usage store, as the directory does for other sessions, so that the list and the name rule see it after the write. For :1856: round the provenance dates to the millisecond when they go into the facts, as for recapAt, endedAt and archivedAt.
  timestamp: 2026-11-19T23:26:15.580522+00:00
- actor: claude-code
  id: 01m7v2t7fdckj3pf9h1canrrq8
  text: |-
    ### implement — changed
    - evidence (findings of 2026-11-19 17:25, all 3 flipped to [x]):
      - SessionImportNames.swift:55 (held names): new tests `twoImportsAtTheSameTimeGetTwoNames` (a `FirstWriteRecorder` in mode `held` holds the first write at a gate: `entered` opens, the second import runs, then `release` opens) and `aFailedImportReleasesItsName` (mode `dropped`: the first write keeps no event and fails). Both passed on the old code; each failed under one mutation: `reserved: []` failed the first ("firstSummary.title != second.title"); a release on failure that keeps the name failed the second ("next.title == Self.title"). File put back after each mutation.
      - RouterSessionDirectory.swift:1805 (decision): `SessionImportNames` now holds a name only while the import runs (`reserve` / `release`, `defer` in `importSession`). `writeImport` records the import as a use in the usage store with the recording root of the session folder (`recordImportUsage(of:in:)`, `markUsed(id, recordingRoot:at:)`), before the release, with no suspension point between them. A store write that fails is logged as a warning; the import does not fail. With no usage store, nothing is recorded (documented). Tests with a launcher that writes to `launcherRecordingRoot` (not a root of the host) and a JSON usage store: `anImportToARootOfTheLauncherIsListed` (failed on the old code: not listed), `aSecondImportToARootOfTheLauncherGetsTheNextFreeNumber` (failed after the release-at-end step and before the root record), `anArchivedImportToARootOfTheLauncherFreesTheName` (failed on the old code: `unknownSession`).
      - RouterSessionDirectory.swift:1856 (dates): `SessionFacts.importedFrom` rounds the provenance dates in its init and in a `didSet` (`RecordedImportProvenance.rounded(_:)`), the one place for `SessionConfiguration.importedFrom` (through `initialFacts`) and the facts. Docs of `importSession`, `SessionFacts.importedFrom` and `SessionConfiguration.importedFrom` state the rounding. Tests: `aLiveSessionGivesItsProvenanceDatesRoundedToTheMillisecond` and `SessionSummaryRecordTests.theFactsRoundTheProvenanceDatesToTheMillisecond` (both failed first); `anImportGivesItsProvenanceDatesRoundedToTheMillisecond` passed before the fix, because the import already read its summary back from the rounded `index.md`.
    - files: Sources/FoundationModelsRouter/Directory/{RouterSessionDirectory,SessionImportNames}.swift, Sources/FoundationModelsRouter/Recording/{SessionFacts,RecordedImportProvenance}.swift, Sources/FoundationModelsRouter/Session/SessionConfiguration.swift; Tests: RouterSessionDirectoryImportTests.swift (7 new; the fixture takes a recorder maker and exposes `recorder`, `profile`, `launcherRecordingRoot`), SessionSummaryRecordTests.swift (1 new), Helpers/FakeSessionLauncher.swift (`importRecordingRoot`), Helpers/FirstWriteRecorder.swift (new).
    - note: the summary that an import returns now has `lastUsedAt` = the time of the import when the directory has a usage store.
    - tests: changed suites 55 tests in 3 suites passed. Full `swift test` once: 3243 tests in 364 suites passed, plus 54 and 19; exit 0; no compiler warnings. Output: scratchpad/full-suite-2.txt. Not committed.
    - next: /review
  timestamp: 2026-11-19T23:38:34.349794+00:00
- actor: claude-code
  id: 01m7v38vcdvc9m1y1mmyba4t39
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (6ee00638) engine counts: 1 finding, 1 confirmed, 0 refuted (9 files). Extra checks gave 3 findings. Open: Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1780 (the doc says the list shows an import at a root of the launcher with no condition; with no usage store it does not), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1865 (an import sets `lastUsedAt`; the Extras contract says `nil` when no client used the session, and the in-memory directory gives `nil`), Sources/FoundationModelsRouter/Directory/SessionImportNames.swift:16 (the same doc has no condition), Tests/FoundationModelsRouterTests/SessionSummaryRecordTests.swift:36 (`subMillisecond` is declared two times).
    - checked and correct: the 3 items of 17:25 are fixed; the held name is released on each exit path (success, write error, read-back error through `defer`; a launcher error occurs before the reservation); no suspension point between the usage record and the release; the rounding is in the initializer and in `didSet`, no other date changes; the tests use gates, not clocks. 4 mutations (no init rounding, no `didSet` rounding, no release, no usage record) each failed at least one new test; files put back, `git status --short` shows only the two `.kanban/` files of this task.
    - next: /implement the 4 items, then /review.
  timestamp: 2026-11-19T23:46:33.485627+00:00
- actor: claude-code
  id: 01m7v3a1m5bj6dgk0bx8yvtswx
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionImportNames.swift, SessionFacts.swift, RecordedImportProvenance.swift, SessionConfiguration.swift; 4 test files (+8 tests, FirstWriteRecorder new)
    - test: green — one full swift test run, 3243 tests in 364 suites (+54, +19), 0 failures
    - commit: 6ee00638
    - review: findings — RouterSessionDirectory.swift:1780 (doc: the list shows an import at a launcher root only with a usage store), :1865 (an import sets lastUsedAt; the Extras contract says nil when no client used it, D184), SessionImportNames.swift:16 (doc: the same condition), SessionSummaryRecordTests.swift:36 (`subMillisecond` declared in two suites)

    Orchestrator decision for :1865: an import is not a use. Record ONLY the recording root of the import in the usage store, with no last use. Change the usage store so that it keeps an entry that holds only a recording root (no pin, no last use), and so that an unpin of such a session keeps the root. lastUsedAt of an import stays nil. Fix the three docs to state exactly when the list shows an import at a root that the host does not give (with a usage store: yes, also after a restart; without one: no).
  timestamp: 2026-11-19T23:47:12.645786+00:00
- actor: claude-code
  id: 01m7v3fz7amfnhdpy2v1bkqmpy
  text: |-
    Research (implement, findings of 17:39):
    - The usage store is `SessionUsageStore` (protocol, Directory/SessionUsageStore.swift) with one conformer, `JSONFileSessionUsageStore` (file `{"version":1,"sessions":{"<ulid>":{"pinnedAt","lastUsedAt","recordingRoot"}}}`). ACPAgent only constructs `JSONFileSessionUsageStore`; no other conformer in the sibling repos.
    - Today `change(...)` and the file read drop each usage with no pin and no last use (`hasPinOrUse`). Thus a root-only entry cannot exist, and an unpin of a session with no use deletes the entry.
    - Plan: new protocol operation `setRecordingRoot(_:of:)` that records only the root and keeps the pin and the last use. The keep rule becomes "a usage that holds a pin, a last use or a recording root stays"; the JSON form and version 1 do not change, so an old file reads as before.
    - Trim risk found: the trim orders the usages that are not pinned by `lastUsedAt ?? .distantPast`. A root-only usage would sort oldest, so with a full store (100 recents) the write of an import would drop its own entry at once. Fix: a usage with no last use is ordered by the time of its session id (`ULID.timestamp`).
    - `subMillisecond` is declared three times (JSONFileSessionUsageStoreTests 0.0004, RouterSessionDirectoryImportTests 0.00025, SessionSummaryRecordTests 0.00025). One shared constant in `RouterTestFixtures` will own it.
  timestamp: 2026-11-19T23:50:26.794829+00:00
- actor: claude-code
  id: 01m7v3wt2504z22tfntw546yfk
  text: |-
    ### implement — changed
    - evidence (findings of 2026-11-19 17:39, all 4 flipped to [x]):
      - Usage store: new requirement `SessionUsageStore.setRecordingRoot(_:of:)` records only the recording root and keeps the pin and the last use. `JSONFileSessionUsageStore` keeps a usage that has a pin, a last use OR a recording root (`holdsAnything`, was `hasPinOrUse`), at the write and at the read. Thus a root-only entry stays, and an unpin keeps the root. A usage with no pin, no last use and no root is still removed. The JSON form and `version` 1 do not change, so an old file reads as before. The trim orders a usage with no last use by the time of its session id (`ULID.timestamp`), so the write of a root to a full store does not drop that usage at once.
      - :1865: `recordImportUsage(of:in:)` is now `recordImportRoot(of:in:)` and calls `setRecordingRoot`, not `markUsed`. An import has `lastUsedAt == nil`.
      - :1780 and SessionImportNames.swift:16: docs of `importSession(_:transcript:)`, `recordImportRoot(of:in:)`, `use(usageStore:)` and the type `SessionImportNames` state: with a usage store the list shows an import at a root that the host does not give, also after a restart; with no usage store it does not (also while the import runs); the held name protects the name only while the import runs. The `Returns:` sentence about the last use is replaced by "The last use is `nil`".
      - SessionSummaryRecordTests.swift:36: one `RouterTestFixtures.subMillisecond` (0.000_25) owns the value; the three copies (also the 0.000_4 copy in JSONFileSessionUsageStoreTests) are removed.
    - RED: stage 1 (API surface only, import still `markUsed`): `aRecordingRootComesBackWithNoUse`, `anUnpinKeepsTheRecordingRoot`, `aboveTheLimitAUsageWithNoUseCountsFromTheTimeOfItsID`, `anImportHasNoLastUse` failed (48 tests, 4 issues). Stage 2 (import calls `setRecordingRoot`, store keep rule old): `anImportToARootOfTheLauncherIsListedAfterARestart`, `aPinThenAnUnpinOfAnImportKeepsItListed` and `aClientUseOfAnImportSetsItsLastUse` failed (`unknownSession` / not listed), with 3 older launcher-root tests. Stage 3 (keep rule): only the trim-order test failed. Stage 4 (order): 48 tests in 2 suites passed.
    - changed test: `anUnpinOfANeverUsedSessionRemovesTheEntry` now pins with no recording root (a usage that holds nothing still goes); `aFileEntryWithNoPinAndNoUseIsRemovedAtTheRead` renamed `aFileEntryThatHoldsNothingIsRemovedAtTheRead`.
    - files: Sources/FoundationModelsRouter/Directory/{SessionUsageStore,JSONFileSessionUsageStore,RouterSessionDirectory,SessionImportNames}.swift; Tests/FoundationModelsRouterTests/{JSONFileSessionUsageStoreTests,RouterSessionDirectoryImportTests,SessionSummaryRecordTests}.swift, Helpers/RouterTestFixtures.swift.
    - tests: 5 suites (store, import, summary record, directory usage, fork) 121 tests passed. Full `swift test` once: 3250 tests in 364 suites passed, plus 54 and 19; exit 0; no compiler warnings. Output: scratchpad/full-suite-3.txt. Not committed.
    - note: a pin then an unpin of any session with a recording root now keeps a root-only entry (before, it was removed when the session had no use).
    - next: /review
  timestamp: 2026-11-19T23:57:27.493908+00:00
depends_on:
- 01M7TY6VQ8MK2NV6ADXMDHQ7RH
position_column: doing
position_ordinal: '80'
title: 'The session directory imports a session: importSession, the importedFrom fact, and the name (D209 (h), part 2)'
---
## Goal

`RouterSessionDirectory` implements `importSession` of Extras with the writer of part 1. The imported session is a recorded root session that is not live, with the origin `import` and its provenance. Decision D209 (h) (`TestudoApp/features/decisions.md`, commit 56a8a59). Brief: `../.briefs/import/router-brief.md` items 2 and 3; overview `overview.md`.

## Depends on

- Part 1 (the writer).
- FoundationModelsExtras D209: `SessionImportRequest`, `SessionImportProvenance`, `SessionDirectoryOrigin.import`, `SessionSummary.importedFrom`, and `importSession(_:transcript:)` on `SessionDirectory` (`extras-brief.md`). Do not start before Extras sends the sha. Update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo). If the Extras protocol requirement has no default, the Router does not compile until this task: do it first when the sha comes.

## Change

1. `SessionFacts.importedFrom: SessionImportProvenance?`, written flat in the frontmatter as `importedFrom`. An old `index.md` with no key reads as `nil`. `SessionSummary(record:)` (^abrxfy5) gives `importedFrom` from the facts.
2. `RouterSessionDirectory.importSession(_:transcript:)`: write the recording with the writer (origin `import`, the provenance), then add the session to the directory as a recorded session that is not live. The name follows D199 (b) with the title of the request: the directory applies only the next free number among the sessions of the folder that are not archived (the ACPAgent gives the base name). Each import makes a new session (Q85 (c)).
3. Send the directory event that a new recorded session gives (as for the other paths that add a session), so the change feed shows it.

## Tests

- [ ] An import writes a recording that restores; the summary is a `root` with origin `import`, and `importedFrom` reads back (also after a restart).
- [ ] `list` of the directory shows the session with the name; a second import with the same title gets the next free number.
- [ ] An old `index.md` with no `importedFrom` reads as nil.
- [ ] A failed write leaves no folder and no directory entry.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e and testudoapp-9a. #d209

## Review Findings (2026-11-19 17:25)

> Scope: `review sha HEAD~1..HEAD` (commit 32c44874). The engine gave 0 findings (14 files reviewed, `.kanban/` not reviewed). The items below come from the extra checks that the orchestrator asked for.

- [x] `Sources/FoundationModelsRouter/Directory/SessionImportNames.swift:55` — No test covers the held names. A mutation that gives `reserved: []` to `SessionDefaultTitle.makeImport` (no held names) keeps all 18 tests of `RouterSessionDirectoryImportTests` green. Add tests to `RouterSessionDirectoryImportTests`: (1) two imports at the same time with the same title in the same folder get two different names (start both before either write ends, for example with a launcher whose model write waits on a gate); (2) an import whose write fails releases its name, so the next import with the same title gets the title, not `-2`; (3) after the list shows an ended import, its reservation is gone (an archive of that session then frees the name for the next import).
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1805` — A held name can stay for the life of the directory. The import writes to `target.configuration.recordingRoot`, but the list and the release in `SessionImportNames.reserve` read only `allRecordingRoots()` (the roots of `useRecordingRoots` and of the usage store). The import records no usage, so when the root of the launcher is not a root of the host, the list never shows the session, the reservation never goes, and each later import with that title in that folder gets the next number. Make sure that the directory lists each session that an import writes (for example, add the recording root of the import to the roots that the directory reads, as the usage store does for a live session), or refuse an import whose recording root the directory does not read, and add a test.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1856` — The dates of the provenance are not rounded when they enter the facts, as `recapAt`, `endedAt` and `archivedAt` are (`MillisecondDate.rounded`). Thus for a `sourceLastDate` or an `importedAt` with a part smaller than one millisecond (for example `Date()`), the `importedFrom` of the returned summary is not equal to `request.provenance`, but the doc of `importSession(_:transcript:)` says it gives "the provenance of `request`" (the Extras in-memory directory gives it equal). A live session that a host starts with `SessionConfiguration.importedFrom` also holds the dates that are not rounded, while its `index.md` holds the rounded dates, so its summary changes after a restart. The tests use only whole-millisecond dates, so they do not show this. Round the provenance dates where they enter the facts (one place for `SessionConfiguration.importedFrom` and `SessionFacts.importedFrom`), state in the docs of `importSession(_:transcript:)`, `SessionFacts.importedFrom` and `SessionConfiguration.importedFrom` that the dates are rounded to the nearest millisecond, and add a test with a date that has a part smaller than one millisecond.

## Review Findings (2026-11-19 17:39)

> Scope: `review sha HEAD~1..HEAD` (commit 6ee00638). The engine gave 1 finding (9 files reviewed, 2 `.kanban/` files not reviewed). The other items come from the extra checks that the orchestrator asked for. Checked and correct: the 3 items of 17:25 are fixed; each exit path of `importSession` releases the held name (a launcher error and a read error of the roots occur before the reservation; a write error, a read-back error and a success go through the `defer`); there is no suspension point between `recordImportUsage(of:in:)` and the release; `SessionFacts.importedFrom` rounds in the initializer and in `didSet`, and no other date changes; the new tests use gates (`RunLatch`), not clocks. Mutations (each file put back): no rounding in the initializer failed `aLiveSessionGivesItsProvenanceDatesRoundedToTheMillisecond`; no rounding in `didSet` failed `theFactsRoundTheProvenanceDatesToTheMillisecond`; no release failed `aFailedImportReleasesItsName` and 2 more; no usage record failed the 3 tests of the launcher root.

- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1780` — The doc of `importSession(_:transcript:)` says, with no condition, "Thus the list and the name rule show the session after the import also when the launcher writes to a root that the host does not give." That is true only when the directory has a usage store. The doc of `recordImportUsage(of:in:)` says that with no usage store "the directory shows an import to a root that the host does not give only until the import ends". The list never shows such a session, also while the import runs: only the held name protects it until the import ends, and after the end a second import with the same title in that folder gets the same name. State in the doc of `importSession(_:transcript:)` that the list and the name rule show the session at a root that the host does not give only when the directory has a usage store (`use(usageStore:)`), and change the sentence of `recordImportUsage(of:in:)` to say that, with no usage store, the list does not show an import to a root that the host does not give, and the name of that import is held only while the import runs.
- [x] `Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1865` — With a usage store, an import sets the `lastUsedAt` of the new session to the time of the import (`markUsed(id, recordingRoot:at: Date())`). The Extras contract of `SessionSummary.lastUsedAt` says: "The time that a client used the session last, or `nil` when no client used it." No client used the imported session: the Extras in-memory directory gives `lastUsedAt == nil` after `importSession`, and the paths of this directory that add a session (`start`, `fork`, restore) do not set it; only a client call of `markUsed(_:)` sets it (D184). Thus an import goes to the top of the Recent list (`SessionOrder.lastUsedFirst`) with no client use, and its summary is not the summary of the in-memory directory. Record the recording root of the import in the usage store with no last use (for example, a `SessionUsageStore` operation that records only the recording root and keeps `lastUsedAt` and `pinnedAt` as they are; note that `setPinned(false, …)` removes a usage that has no last use, so an unpin must keep the recording root), so that the returned summary gives `lastUsedAt == nil`. Remove "The last use is the time of the import when the directory has a usage store." from the `Returns:` doc of `importSession(_:transcript:)`, and add a test that an import with a usage store gives `lastUsedAt == nil` and is still listed.
- [x] `Sources/FoundationModelsRouter/Directory/SessionImportNames.swift:16` — The doc says, with no condition, "The list then shows the imported session, because the directory records its recording root before the release", and "Thus a choice sees each other import either by its reservation or by its session." With no usage store, an import to a root that the host does not give is not listed after its end, so a later choice sees neither its reservation nor its session. State that the list shows the session after the release only when the directory has a usage store or the recording root of the import is a root of the host.
- [x] `Tests/FoundationModelsRouterTests/SessionSummaryRecordTests.swift:36` `reuse/reuse` — The new `subMillisecond` constant (0.000_25 s) is a private duplicate of the `subMillisecond` constant that the new import tests already declare. Two copies of the same test value can drift apart, and the two suites then test different sub-millisecond offsets while the comments say they are the same. Declare the constant once in a shared test helper, for example beside `RouterTestFixtures`, and have both suites reference it. Alternatively, keep one private copy and make the other suite's comment point to it. Either way, one definition should own the value.