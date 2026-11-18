---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qx1959mjed7hfmprqfsaka
  text: |-
    Research (implement):
    - The ledger (`messages.jsonl`) keeps each directory message as delivered and unread when its mail goes in the queue. The pump take does not mark it read. So a kept message is already unread in `inbox(of:)`. The gap: the scan of `inbox/` removes a file whose id the ledger holds, with no delivery (crash rule). A file with the same id thus needs a ledger mark. Plan: a new ledger line `kept(id:)`; the scan delivers a file when the ledger has no message with the id, or the message is kept and not read. A second `delivered` line of the same id replaces the message and clears the mark.
    - The waiting mail is read with no change to the session actor: `cancelAll()` reports `MailFate.cancelledOrLost` for each waiting mail before `signalDone`. While a session archives, `Registry.apply(_:)` moves such a message from `awaitingDelivery` to a kept list instead of a drop. `takeArchived` takes the kept list and the rest of `awaitingDelivery` of the session. `awaitingDelivery` must also hold the user header line, so its value becomes a small struct.
    - `archiveLive` no longer calls `scanInbox(of:)`: the files of `inbox/` stay as they are. A watcher scan during the archive skips the session (else a mail put after the cancel signal could start an answer).
    - Memory-only session: no folder, so no inbox file; it cannot open again after the archive. Its waiting mail ends cancelled, with no `messageDelivered` (decision, to document and test).
    - Reference: Extras `InMemorySessionDirectoryState.archive` sets `isQueued = false` on the deliveries, no `messageDelivered`.
  timestamp: 2026-11-18T17:59:50.697851+00:00
- actor: claude-code
  id: 01m7qxxmafdx2qa0eeaknecybx
  text: |-
    Implementation landed (not committed).
    - `SessionMessageLedger`: new line `kept(id:)`, `markKept(_:)`, `awaitsDelivery(of:)`. A second `delivered` line of a kept id replaces the message and ends the mark. A read kept message is not delivered again (a read mark withdraws it, as it withdraws mail in a queue).
    - `RouterSessionDirectory`: `Registry.awaitingDelivery` now holds `AwaitedDelivery` (message + user header). New `Registry.keptMail`, `startKeepingMail(of:)`, `takeKeptMail(of:)`; `apply(.cancelledOrLost)` moves a message of an archiving session to `keptMail`. `archiveLive` no longer calls `scanInbox(of:)`; `scanInbox` skips a session while it archives (`isArchiving`). `takeArchived` returns the kept messages; `keepInInbox(_:of:)` marks each one kept in the ledger first, then writes `inbox/<id>.md` with sender, client id, reply id, chain depth, source session and header line. No change to the session actor code.
    - Decision, memory-only session: no `inbox/` folder and it cannot open again after the archive, so its waiting mail ends cancelled with no file and no `messageDelivered`. Documented on `keepInInbox` and tested.
    - Fixture note: the reading router of `SessionDirectoryRouterPair` has another router id, so its launcher cannot restore a session of the recording router (`TranscriptTreeError.sessionNotFound`). The reopen tests use a `FakeSessionLauncher` over `recordingProfile` and the live directory; the inbox read goes through the reading directory (disk).
    - Renamed `aWaitingMessageOfAnArchivedSessionIsDropped` to `aWaitingMessageOfAnArchivedSessionLeavesItsQueue` (its name said "dropped").
    - Two tests passed at once at RED (no `messageDelivered` at the archive; memory-only ends cancelled): the old code also gave no event. They guard the new code.
  timestamp: 2026-11-18T18:15:19.631284+00:00
- actor: claude-code
  id: 01m7qxxq3exc6nxfp06tkg1nrb
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionMessageLedger.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift (new, 8 tests), Tests/FoundationModelsRouterTests/SessionMessageLedgerTests.swift (+6 tests), Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift (rename), Tests/FoundationModelsRouterTests/RouterSessionDirectoryQueuedEventTests.swift (AwaitedDelivery). Full `swift test`: 2959 tests in 342 suites passed, 49 in 26 passed, 19 in 3 passed; 0 failures; 0 warnings on a forced rebuild of the changed files.
    - next: /review
  timestamp: 2026-11-18T18:15:22.478326+00:00
- actor: claude-code
  id: 01m7qy82mz6qhw0246712ggqcv
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`: engine 0 findings (14 attempted, 0 failed). Orchestrator check: 1 finding at Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift:110 (the reopen helper waits for messageDelivered with no end, so the reopen test hangs and does not fail against the defect that it names).
    - checked with no finding: the "kept" ledger line (a kept message is delivered one time at the next open and the delivery ends the mark; a read kept message is removed with no delivery; a ledger with no "kept" line reads as before, because the synthesized Codable of `Line` keeps the old cases and `add` appends when the id is new). No change in `Sources/FoundationModelsRouter/Session/`; the reopen test still expects the running turn to end cancelled.
    - next: implement the finding, then review again.
  timestamp: 2026-11-18T18:21:01.983718+00:00
- actor: claude-code
  id: 01m7qy8jw9hstkyce66mn941v3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionMessageLedger.swift, 4 test files
    - test: green — swift test in the implement step, 2959 tests in 342 suites (+49, +19), 0 failures
    - commit: f558037e
    - review: findings — RouterSessionDirectoryArchiveMailTests.swift:110 (the reopen helper waits with no end, so the tests hang and do not fail)
  timestamp: 2026-11-18T18:21:18.601946+00:00
- actor: claude-code
  id: 01m7qyjr59dzbabk1g4r8cggaw
  text: |-
    Finding fixed (bounded-failure, RouterSessionDirectoryArchiveMailTests.swift).
    - `reopen(_:awaiting:in:)` no longer uses `nextDelivery(of:)`. After the restore it calls `scanInbox(of:)` of the live directory itself (the first scan of the watcher runs in a task the test does not wait for, so with no direct scan the idle wait could end before the mail is in the queue). Then it waits for `awaitIdle()` of the opened session, emits the marker, reads with `next(through:)`, and finds the `messageDelivered` of the message in those events (new helper `delivery(of:in:)`). It now also gives the opened session; the separate `awaitIdle` expectation in the first reopen test is gone, because the helper already waits for idle.
    - No other read in the file can wait with no end: each other event read goes through the marker, and each `awaitTerminal` is on a session that the archive closes.
    - Proof (temporary defect, reverted): defect 1 — the scan removed a kept file with no delivery (`awaitsDelivery(...) && false`). `theQueuedMessageReachesTheSessionWhenItOpens` FAILED at the delivered expectation; `anInboxFileStaysAndReachesTheSession` failed earlier (the watcher scan before the archive removed the file), so it did not reach the reopen. Defect 2 — `scanInbox` skips every file (`for file in files where files.isEmpty`): both tests FAILED at `delivered?.text == Self.text` after 0.05 s, no hang. Source reverted from a backup; `git status` shows no change in Sources.
  timestamp: 2026-11-18T18:26:51.689180+00:00
- actor: claude-code
  id: 01m7qyjtmycancvq0jmcr2xk6p
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift. Suite filter `FoundationModelsRouterTests.RouterSessionDirectoryArchiveMailTests`: 8 tests passed. With a temporary scan defect, the two reopen tests FAILED in 0.05 s (no hang); defect reverted. Full `swift test`: 2959 tests in 342 suites passed, 49 in 26 passed, 19 in 3 passed; 0 failures; no compiler warnings.
    - next: /review
  timestamp: 2026-11-18T18:26:54.238073+00:00
- actor: claude-code
  id: 01m7qynd27fry83ak0bpas0rgv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (5fccf24b): 0 findings (7 attempted, 0 failed, 1 refuted). 1 file reviewed: Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift. 4 `.kanban/` files not reviewed (ignore rule). The prior finding at RouterSessionDirectoryArchiveMailTests.swift:110 is checked.
    - bounded failure check: `reopen(_:awaiting:in:)` does not use `nextDelivery(of:)` now. Each wait in it has an end: `scanInbox(of:)` is awaited; `awaitIdle()` ends when the session has no work (with no delivered mail, no turn starts); `next(through: marker)` ends at the marker that the helper emits. Thus `theQueuedMessageReachesTheSessionWhenItOpens` and `anInboxFileStaysAndReachesTheSession` fail at `delivered?.text == Self.text` when the kept mail does not arrive. They do not hang. The implementer comment records the same result with a temporary defect (both tests failed in 0.05 s).
    - next: none. Task moved to done.
  timestamp: 2026-11-18T18:28:18.631541+00:00
- actor: claude-code
  id: 01m7qynyfcv13mesf24f34ngv3
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — RouterSessionDirectoryArchiveMailTests.swift (the reopen helper waits for idle and reads to a marker; a temporary defect made both tests fail in about 0.05 s)
    - test: green — swift test in the implement step, 2959 tests in 342 suites (+49, +19), 0 failures
    - commit: 5fccf24b
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-18T18:28:36.460613+00:00
depends_on:
- 01M7QTQCW62ZNN9CXFTVE3TV8Y
position_column: done
position_ordinal: ffffffffffb280
title: An archive keeps the waiting mail as unread inbox messages (D204)
---
## Goal

An archive hides a session; it does not delete it. The mail that waits is kept. Decision D204 (`TestudoApp/features/decisions.md`, commit 9281f9c). Brief: `../.briefs/archive/router-brief.md`, item 2.

## Depends on

FoundationModelsExtras (the D204 change, see the unarchive task). The dependency on the unarchive task is for the test that archives, unarchives and opens a session.

## Current behavior

`archiveLive` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:2794-2808`) calls `scanInbox(of:)` and then `session.cancelAll()` (`:2800`). The doc (`:2776-2779`) says that it "drops each waiting mail, also the mail of a message that waits for the end of the turn". Then it writes `archivedAt` with `updateRecord`, waits for the cancel, takes the session off the live list with `takeArchived` (`:2863-2876`, `forgetDeliveries` at `:2869`) and closes it.

## Change

- The running turn still ends cancelled.
- Each message that waits in the queue of the session, and each file of its `inbox/` folder, stays as an unread inbox message: a file in `inbox/` for a durable session.
- A message that goes from the queue to the inbox file keeps its sender, client id, source session and header (the inbox file format of ^ty244es).
- `messageDelivered` does not come for these messages at the archive. It comes when a client opens the session and takes them (the rule of ^jf3j3v5).
- A session that is not durable (no recording folder): write down what happens to its waiting mail, and test it.
- Change the doc of `archiveLive` (`:2776-2779`): an archive keeps the mail.
- The session actor code (`Session/RoutedSessionActor*.swift`, `MailFate.swift`) has pump and cancellation invariants. Read `routed-session-cancellation-invariants` in the memory folder before a change there.

## Tests

- [x] Live session with a running turn and one queued message: archive, then unarchive, then restore with the launcher. The turn ended cancelled, and the queued message is in the inbox as unread and reaches the session when it opens.
- [x] Inbox files that wait at the archive stay, and reach the session when it opens after an unarchive.
- [x] No `messageDelivered` at the archive for a kept message.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d204

## Review Findings (2026-11-18 12:15)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift:110` `orchestrator/bounded-failure` — The helper `reopen(_:awaiting:in:)` waits for the `messageDelivered` event with `nextDelivery(of:)`, and that read has no end: the event stream of the live directory does not end in the test. When the defect that `theQueuedMessageReachesTheSessionWhenItOpens` (line 171) names is present (the old archive drops the queued mail, or the scan removes the kept file with no delivery), no `messageDelivered` comes and the test hangs. It does not fail. The same helper makes `anInboxFileStaysAndReachesTheSession` (line 197) hang when the scan does not deliver the kept file. Make the read bounded with no time limit: after the restore, wait until the opened session is idle, then `emit` a marker and read with `next(through:)`, and expect the `messageDelivered` of the message in those events. Then make the test fail against the old archive code (it must fail, not hang) before it passes against the new code.