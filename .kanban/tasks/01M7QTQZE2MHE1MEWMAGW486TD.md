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