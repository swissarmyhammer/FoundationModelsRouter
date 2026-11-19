---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qzc6tbfyfb03mw4a6s9r4k
  text: |-
    Research and decisions (implement step).

    - Extras at 87d1da9: `InMemorySessionDirectoryState+Messages.deliver` puts a message to a target that is not live in its inbox for each sender, and adds the note "archived" (`archivedNote`) when the target is archived. The protocol doc of `SessionDirectory.send` says: a recorded target gets the message in its inbox "for a session sender and for a user sender".
    - Decision 1 (user message with no source session): an ARCHIVED target gets the inbox file with the note `archived`, also for a user sender with no source session. Reason: the card says "unless the Extras contract says otherwise", and the Extras contract (protocol doc and in-memory directory) gives the inbox to each sender. D204 (i)(4) also says a refusal must not lose the message. The router rule for a RECORDED target that is not archived does not change: a user sender with no source session still gets `refused` with `userNeedsLiveSessionReason` (D199 (f), the at-sessions brief). This difference from the in-memory directory existed before this task.
    - Decision 2 (a LIVE archived session, opened with session/load and not unarchived): the resolver gives `.sendToRecorded` for it too. The file goes to the folder of the live session (new `inboxFolder(of:)`: the live recording directory, else `recordedFolder(of:)`). `scanInbox(of:)` does not scan a live session whose facts hold `archivedAt`, so the watcher does not deliver the file and no turn starts. `unarchiveLive` calls `scanInbox(of:)` after its events, so the waiting files go to the session at the unarchive. Side effect: a session/load of an archived session no longer delivers the kept mail of ^2b3p9bs at the load; the mail waits for the unarchive.
    - `SessionAddressResolution.archivedReason` is removed; the note is `RouterSessionDirectory.archivedNote`.
    - Short id and slug: the router has no short id or slug address. The client resolves them with `SessionReference.resolve`, which skips each summary with the state `archived`. A test checks that the summaries of the directory make both resolve to `.none`.
    - Checked that the two new guards are needed: with the `archivedAt` guard in `scanInbox` removed, "a live archived session keeps the message in its inbox" fails; with the scan in `unarchiveLive` removed, "an unarchive of a live archived session delivers the message" fails.
  timestamp: 2026-11-18T18:40:45.899465+00:00
- actor: claude-code
  id: 01m7rh22ed7x42fbb27477vx1a
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift; tests: new RouterSessionDirectoryArchivedTargetTests.swift (8 tests), changed SessionAddressResolutionTests, RouterSessionDirectoryArchiveTests, RouterSessionDirectoryArchiveMailTests (helpers made internal), RouterSessionDirectoryDeliveryTests, RouterSessionDirectorySourceSessionTests, RouterSessionDirectoryQueuedEventTests.
    - full suite, run 1: 17 issues. 2 were mine: RouterSessionDirectoryQueuedEventTests "a message to an archived session is refused and gives no message event" still expected `refused` (got `sent`). I changed it to "a message to an archived session gives only messageQueued" (passes, suite 11/11). The other 15 were "the wait at <file>:<line> did not end inside its limit of 60 s" in ToolBodyHoldsNoLockTests (8), LockWaitStallWatchTests (3), ChildStarvationRegressionTests, NestedGenerationReentryTests, SubmissionQueueSpikeTests, ToolResultCompactionTests; other swift test processes ran on the machine (load about 19).
    - full suite, run 2 (after the QueuedEvent fix): the test process stopped, no output for more than 30 minutes at 0% CPU; I killed it. The stuck test is not known (buffered output; the log ended in the name "stop, act, stop, act: each of the four reasoning stops recovers"). No issue was recorded before the stop.
    - full suite, run 3 (no code change after run 2; I ran it because run 2 gave no result): 2969 tests in 343 suites passed, plus 49 and 19; exit 0. This does NOT prove the suite is green: the run-1 timeouts and the run-2 hang are not deterministic. New task ^szyxq9z records them.
    - next: /review
  timestamp: 2026-11-18T23:49:48.109828+00:00
- actor: claude-code
  id: 01m7rhajzs2ns0hhtnvv22v0h6
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (1e1fd9ac): 2 findings (2 confirmed, 1 refuted). Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:238, Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchivedTargetTests.swift:75.
    - additional checks (pass): (1) Each wait in the new tests ends. `next(through:)` stops at a marker that the test sends after the iterator exists. `awaitIdle()` returns when no turn starts, and the latch is open. (2) The scan guard does not stop delivery after an unarchive. `updateRecord` writes `archivedAt = nil` under the record lock before `scanInbox(of:)` reads `session.facts`. (3) `messageQueued` comes once for an archived target. `sendToRecorded` sends it one time. The scan after the unarchive calls `hand(...)` with `isQueued` false, so it sends no second event.
    - next: implement the 2 findings, then review again.
  timestamp: 2026-11-18T23:54:27.193300+00:00
- actor: claude-code
  id: 01m7rhb2yp3pc333xh2yynz63e
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — SessionAddressResolution.swift, RouterSessionDirectory.swift, 7 test files
    - test: red then unclear — run 1: 2 own failures (fixed) and 15 unrelated 60 s wait timeouts; run 2: hung; run 3 (no change): 2969 tests passed. The unrelated tests are on ^szyxq9z.
    - commit: 1e1fd9ac
    - review: findings — RouterSessionDirectoryArchiveTests.swift:238 (the inbox file is not read back), RouterSessionDirectoryArchivedTargetTests.swift:75 (copied send helper)
  timestamp: 2026-11-18T23:54:43.542528+00:00
- actor: claude-code
  id: 01m7rhjz3h5ndwppb405dag79d
  text: |-
    Review findings, implement pass 2.
    - Finding 1: the live archivedAt test and the restart test now read the inbox file back with `RouterSessionDirectoryArchiveMailTests.inboxFile(_:of:)` and check the text. `archivedReceipt(of:to:)` takes a `MailID` (not optional), because both tests now get the id with `#require`. The check can fail: with the `SessionInboxFile.write` line in `writeInboxFile` removed for a moment, both tests failed with "no such file" (NSCocoaErrorDomain 260), and the 9 other tests of the suite passed. I put the line back (file copy from a backup; `git diff Sources/` is empty).
    - Finding 2: one send on `RouterSessionDirectoryArchiveTests.Fixture`: `static send(_:to:from:sourceSession:through:)` (sender and directory are parameters) and `sendMessage(_:to:from:sourceSession:)` (through liveDirectory, gives the message id). The private send helpers of the archive suite, the archived-target suite and the archive-mail suite (also a copy) are removed, and all three suites call the Fixture helpers. The memory-only test of the archive-mail suite also uses `Fixture.send`.
    - Filtered run: Archive, ArchivedTarget, ArchiveMail suites: 27 tests in 3 suites passed.
  timestamp: 2026-11-18T23:59:01.745770+00:00
- actor: claude-code
  id: 01m7rhkvt5ncnwdk27b8zsmb9p
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift, RouterSessionDirectoryArchivedTargetTests.swift, RouterSessionDirectoryArchiveMailTests.swift. Check 1 shown to fail: with the `SessionInboxFile.write` line in `writeInboxFile` removed, the 2 changed tests failed ("no such file"); line put back, `git diff Sources/` empty. Filtered: 27 tests in 3 suites passed. Full `swift test` (one run): 2969 tests in 343 suites passed, plus 49 and 19; exit 0; no warnings.
    - next: /review
  timestamp: 2026-11-18T23:59:31.141091+00:00
- actor: claude-code
  id: 01m7rhqcfmzxb3qtwmw6m71yya
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (496edc13). 3 findings (3 confirmed, 0 refuted). The 2 items of "Review Findings (2026-11-18 17:50)" are fixed: the live-archived test and the restart test read the inbox file back, and the archived-target suite calls the shared `Fixture.send`. New: Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift:283, Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:87, Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:395.
    - next: implement the 3 items of "Review Findings (2026-11-18 17:59)". The task stays in review.
  timestamp: 2026-11-19T00:01:26.516915+00:00
- actor: claude-code
  id: 01m7rhqxwdf24ev7v3pgvajaf6
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RouterSessionDirectoryArchiveTests.swift, RouterSessionDirectoryArchivedTargetTests.swift, RouterSessionDirectoryArchiveMailTests.swift (inbox read-back shown to fail; one Fixture send helper)
    - test: green — one full swift test run, 2969 tests in 343 suites (+49, +19), 0 failures
    - commit: 496edc13
    - review: findings — RouterSessionDirectoryArchiveMailTests.swift:283, RouterSessionDirectoryArchiveTests.swift:87, RouterSessionDirectoryArchiveTests.swift:395 (all reuse in tests)
  timestamp: 2026-11-19T00:01:44.333511+00:00
- actor: claude-code
  id: 01m7rjanpkyfg9yswd5d3t17ye
  text: |-
    Implement pass 3 (the 3 items of "Review Findings (2026-11-18 17:59)").
    - One send helper in the new file `Tests/FoundationModelsRouterTests/Helpers/RouterSessionDirectory+TestSend.swift`: `RouterSessionDirectory.send(_:to:from:sourceSession:awaitingDelivery:)` (one form for a `SessionAddress`, one for a session id that forwards `.session(id)`), and `sendMessage(_:to:from:sourceSession:awaitingDelivery:)` (send and `#require` of the message id). `awaitingDelivery: true` uses `sendAndAwaitDelivery(_:)`; that is the contract difference of the delivery and source-session suites. The file also holds `SessionSendReceipt.archived(_:to:)`, the `sent` receipt with the note "archived".
    - Finding 1: the directory, not the Fixture, holds `sendMessage`. Reason: the memory-only test has no Fixture, so an instance method of the Fixture with a `through directory:` parameter cannot serve it. The memory-only test calls `router.sessionDirectory.sendMessage(...)`; the archive suites call `fixture.liveDirectory.sendMessage(...)`. `Fixture.send` and `Fixture.sendMessage` are removed.
    - Finding 2: the private send helpers of the inbox, delivery and source-session suites are removed; the suites call the shared helper. Each suite has a `user` constant for its UI sender. The assertions of the existing inbox tests did not change. `sendAndAwaitDelivery(_:fromClient:to:)` now forwards to the shared helper.
    - Finding 3: `RouterSessionDirectoryArchiveTests.sendToArchivedSession(_:through:)` sends, takes the id with `#require`, checks the archived receipt and the inbox file text. The live-archived test, the restart test and the archived-target full-id test call it. The archived-target test "a send to an archived session writes the message as a file in its inbox" is merged into the full-id test, because the helper does the same check.
    - Other copies removed in the changed files: the inline archived receipt in the delivery and source-session suites (now `SessionSendReceipt.archived`); the "live root with archivedAt" setup of the archive test and of `liveArchivedSession` (now `Fixture.makeLiveArchivedRoot()`).
    - Filtered: 6 suites (Archive, ArchivedTarget, ArchiveMail, Inbox, Delivery, SourceSession), 74 tests passed; after the last change, Archive and ArchivedTarget, 18 tests passed.
  timestamp: 2026-11-19T00:11:58.547721+00:00
- actor: claude-code
  id: 01m7rjbbc17j3dhc91bkjmcryf
  text: |-
    ### implement — changed
    - evidence: new Tests/FoundationModelsRouterTests/Helpers/RouterSessionDirectory+TestSend.swift; changed Helpers/RouterSessionDirectory+SendAndAwaitDelivery.swift, RouterSessionDirectoryArchiveTests.swift, RouterSessionDirectoryArchivedTargetTests.swift, RouterSessionDirectoryArchiveMailTests.swift, RouterSessionDirectoryInboxTests.swift, RouterSessionDirectoryDeliveryTests.swift, RouterSessionDirectorySourceSessionTests.swift. No change in Sources/. Filtered: 74 tests in 6 suites passed. Full `swift test` (one run): 2968 tests in 343 suites passed (one test fewer: the archived-target inbox-file test is merged into the full-id test), plus 49 and 19; exit 0; no warnings in the test files.
    - next: /review
  timestamp: 2026-11-19T00:12:20.737209+00:00
depends_on:
- 01M7QTQCW62ZNN9CXFTVE3TV8Y
position_column: doing
position_ordinal: '80'
title: A message to an archived session goes to its inbox (D204)
---
## Goal

A message to an archived session goes to its inbox, and the session stays archived. Decision D204 (`TestudoApp/features/decisions.md`, commit 9281f9c). Brief: `../.briefs/archive/router-brief.md`, item 3; Extras rule in `extras-brief.md` part 3.

## Depends on

FoundationModelsExtras (the D204 change: the note `archived` in the `reason` of a `sent` receipt). The dependency on the unarchive task is only the order of work.

## Current behavior

The resolver refuses a session id of an archived session with the reason `archived` (`Sources/FoundationModelsRouter/Directory/SessionAddressResolution.swift:39-40`, `:56`). A short id and a slug do not match an archived session.

## Change

- In `SessionAddressResolution.reaching(session:)` (`:56`), an archived target is the same as a recorded target: `.sendToRecorded(target.id)`.
- The receipt is `sent` with the note `archived` in `reason`. The directory sends `messageQueued` (the rule of ^gfnste0). The session stays archived and starts no turn.
- An archived session that is live (opened with `session/load` and not unarchived): decide and write down the rule. It must stay archived and start no turn.
- Keep: a short id and a slug do not match an archived session (D199 (d)). Only the full id reaches an archived session. `@<agent>` with only an archived session of that agent starts a new session (D199 (e)).
- A user message with no source session to an archived session: the same rule as for a recorded session (refused with `userNeedsLiveSessionReason`), unless the Extras contract says otherwise.

## Tests

- [x] A send by full id to an archived session: receipt `sent`, reason `archived`, one `messageQueued`, a file in `inbox/`, the state stays `archived`.
- [x] A send by short id or slug that matches only an archived session: no match, not a delivery to the archived session.
- [x] After an unarchive and an open, the message reaches the session.
- [x] Update the existing tests that expect a refusal with the reason `archived`.

## After

Push when green. Send the sha to foundationmodelsmultitool-89 and testudoapp-9a. #d204

## Review Findings (2026-11-18 17:50)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:238` `completeness/inverse-operation-coverage` — The test named 'a live session whose record holds archivedAt reads archived, and a send to it goes to its inbox' never checks the inbox. It asserts the receipt, the archived state and that pendingMessages is empty, but it does not read the inbox file back. The write side of the new behaviour is therefore unproven: a send could return the archivedNote receipt and still write no file, and the test would pass. After the send, read the file back with the message id (`SessionInboxFile.url(of:in:)` and `SessionInboxFile.read`, or the existing inbox-file helper) and assert that it exists and holds the sent text. Apply the same check to the restart test.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchivedTargetTests.swift:75` `reuse/reuse` — The new private helper `send(to:in:)` repeats the send helper of the archive suite. That helper sends the same kind of UI message to a session id. It is private to another suite, so this suite cannot call it, and the two copies can drift apart. Move the send helper to a shared place, such as a static on `RouterSessionDirectoryArchiveTests.Fixture` or an internal helper, and take the sender as a parameter. Then both suites call one copy. If the sender difference is kept, pass it in rather than writing a parallel copy.

## Review Findings (2026-11-18 17:59)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveMailTests.swift:283` `reuse/reuse` — The memory-only test repeats the body of `Fixture.sendMessage` inline: it calls `Fixture.send` and then takes `receipts.first?.messageID` with `#require`. The existing helper was not extended with a directory parameter, so the same send-and-require sequence is written out a second time. Add a `through directory:` parameter to `Fixture.sendMessage`, defaulting to `liveDirectory`, and call it here with `router.sessionDirectory`, so both paths use one send-and-require helper.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:87` `reuse/reuse` — The new `Fixture.send` helper repeats a send helper that already exists in another test suite. `RouterSessionDirectoryInboxTests.send` does the same job, so the test code now has two copies that can drift apart. Move the one send helper into a shared test helper file, such as `Tests/FoundationModelsRouterTests/Helpers/`, and have the archive, delivery and inbox suites call it. If the other suites need a different contract, parameterize the shared helper instead of keeping a parallel copy.
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryArchiveTests.swift:395` `reuse/reuse` — The restart test repeats the send, the `#require` of the message id, the receipt check and the inbox-file text check that the live-archived test already performs. The two copies are near-identical and will drift apart. Extract a helper such as `sendToArchivedSession(_:through:)` that returns the message id after checking the archived receipt and the inbox file, and call it from both tests. Each test keeps its own remaining assertions.
