---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7nqpyc4efdgf8wp9mmjm9g0
  text: 'Extras task 01M7NQNHCZY77SHDX2H1969AEQ changes `InMemorySessionDirectory`: it does not restore a recorded target through the launcher, and it puts the message in the inbox, as the Router does. The Router tests do not use `InMemorySessionDirectory` today (no match in `Sources` or `Tests`). If a test that expects the restore fails after the Extras update, change the test to expect the inbox.'
  timestamp: 2026-11-17T21:48:20.228572+00:00
- actor: claude-code
  id: 01m7qj08j4ntzh8pwdzjyg6sgs
  text: |-
    Research:
    - The inbox file already has a sender kind: the `from` key. `session:<ULID>` is a session sender, `user` is a user sender. A file with no `from` is a hand-written user file (this stays). An old Router file has `from: session:<ULID>`, so it reads as a session sender.
    - The file has no form for a client id today: `write` throws `userSenderNotWritten` for a user sender with a client id other than `user`. UI senders use real client ids (for example `client-a`), so the send to a recorded target would throw. Decision: add an optional `clientID` key. The writer writes it only for a user sender with a client id other than the default. This makes `userSenderNotWritten` dead, so it goes.
    - Header choice: send time. `send` already makes the `UserMessageHeader` from the live summary, else the recorded summary. The file keeps the header line in a `userHeader` key. The scan is synchronous and cannot read the recorded summaries (async), so a header made at delivery time could not name a recorded source. A file with `sourceSession` and no `userHeader` (a hand-written file) gets a header from the live summary at delivery.
    - New keys: `clientID`, `sourceSession`, `userHeader`.
    - The archived target test exists already in RouterSessionDirectorySourceSessionTests (`anArchivedTargetIsRefused`). The no-source refusal test exists (`aUISenderIsRefusedForARecordedSession`).
  timestamp: 2026-11-18T14:47:02.980413+00:00
- actor: claude-code
  id: 01m7qjbcxcj46zvtwfgvvfdmzh
  text: |-
    Implementation landed.
    - `sendToRecorded` writes an inbox file and gives `sent` for a session sender and for a user sender with a source session. The refusal `userNeedsLiveSessionReason` stays only for a user sender with no source session.
    - Inbox file: new optional keys `clientID`, `sourceSession`, `userHeader`. The `from` key is the sender kind (`user` or `session:<ULID>`). The card says "no kind means a session sender": the old Router file always has `from: session:<ULID>`, so it reads as a session sender (test `anOldFormatFileReadsAsASessionMessage`). A file with no `from` stays a hand-written user file, as before. No compatibility code: an old file has no new keys, so it reads with no change (ARCHITECTURE.md: no backward compatibility).
    - `userSenderNotWritten` is removed: the file keeps each client id now. The old test `aUserSenderWithAClientIDIsNotWritten` became `aUserSenderWithAClientIDRoundTrips`.
    - Header time: send time. The file keeps the line; the scan uses `UserMessageHeader(line:)`. A hand-written file with `sourceSession` and no `userHeader` gets the header from the live summary at delivery (the scan has no suspension point, so it cannot read recorded summaries).
    - The scan gives the delivered `SessionMessage` the `sourceSession` of the file.
    - Doc comments of `send`, `sendToRecorded`, `deliver`, `deliverDirectly`, `writeInboxFile` and `userNeedsLiveSessionReason` are updated.
    - Event task ^jf3j3v5 not touched: the recorded target gets no `messageDelivered` until a host opens it, the same as the Extras in-memory directory.
  timestamp: 2026-11-18T14:53:07.884927+00:00
- actor: claude-code
  id: 01m7qjbfrg5js2ena9mmq223a4
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Sources/FoundationModelsRouter/Directory/SessionInboxFile.swift, Sources/FoundationModelsRouter/Directory/UserMessageHeader.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift, Tests/FoundationModelsRouterTests/SessionInboxFileTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift. Focused run: 69 tests in 3 suites passed. Full `swift test`: 2898 tests in 336 suites, 48 tests in 26 suites, 19 tests in 3 suites passed, 0 issues, no build warnings.
    - next: review
  timestamp: 2026-11-18T14:53:10.800376+00:00
- actor: claude-code
  id: 01m7qjhf1spkpey7w0nv1asmbk
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (e0c7e105); 2 findings, 2 confirmed, 0 refuted — Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift:199, Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift:214
    - next: implement the 2 reuse findings in the `## Review Findings (2026-11-18 08:53)` section, then review again.
  timestamp: 2026-11-18T14:56:26.681960+00:00
- actor: claude-code
  id: 01m7qjhy3t9f6cqf63tv7acqak
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — RouterSessionDirectory.swift, SessionInboxFile.swift, UserMessageHeader.swift, 3 test files
    - test: green — swift test in the implement step, 2898 tests in 336 suites (+48, +19), 0 issues, 0 warnings
    - commit: e0c7e105
    - review: findings — RouterSessionDirectorySourceSessionTests.swift:199, RouterSessionDirectorySourceSessionTests.swift:214
  timestamp: 2026-11-18T14:56:42.106180+00:00
- actor: claude-code
  id: 01m7qjpngpqss81pnkh02hj68c
  text: |-
    Review findings fixed.
    - Finding 1 (reuse, `send(toRecorded:from:in:)`): removed. The existing `send(to:from:in:)` now has the parameter `awaitingDelivery: Bool = true`. It builds the message one time, and calls `sendAndAwaitDelivery` or `send`. The 4 recorded-target tests call `send(to: .session(target), ..., awaitingDelivery: false)`.
    - Finding 2 (reuse, `awaitDelivery`): both private copies removed (SourceSession suite and Inbox suite). One shared helper `nextDelivery(of:) -> SessionMessage?` is now in the existing iterator extension in `Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift`, beside `next(count:)` and `next(through:)`. The Inbox suite calls `events.nextDelivery(of: id) != nil` (8 calls).
    - Note: `sendAndAwaitDelivery` waits only for `delivered` and `queued` receipts, so a `sent` receipt does not wait. The flag makes the intent clear at the call.
  timestamp: 2026-11-18T14:59:17.142192+00:00
- actor: claude-code
  id: 01m7qjprm4d9n7dg381gsffpkw
  text: |-
    ### implement — changed
    - evidence: 3 files — Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift, Tests/FoundationModelsRouterTests/Helpers/SessionDirectoryEventReads.swift. Focused run (`FoundationModelsRouterTests.RouterSessionDirectorySourceSessionTests|FoundationModelsRouterTests.RouterSessionDirectoryInboxTests`): 40 tests in 2 suites passed. Full `swift test`: 2898 tests in 336 suites, 48 tests in 26 suites, 19 tests in 3 suites passed, 0 failures, no compiler warnings (one SwiftPM build-system line about the mlx-swift_Cmlx.bundle node, not from source).
    - next: review
  timestamp: 2026-11-18T14:59:20.324317+00:00
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
position_column: doing
position_ordinal: '80'
title: Put a user message with a source session in the inbox of a recorded target (D199 (f))
---
## Goal

A user message with a source session reaches a recorded target that is not live, as a message from a session does. Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 2. Decision D199 (f).

## Current behavior

`sendToRecorded` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:1338-1349`) refuses a user sender with `userNeedsLiveSessionReason` (`:89`, `:1341-1342`). A session sender gets an inbox file (`writeInboxFile`, `:1263`) and the receipt `.sent`.

## Change

- A user sender with a source session gets an inbox file and the receipt `.sent`.
- Keep the refusal `userNeedsLiveSessionReason` only for a user sender with no source session.
- The inbox file (`Directory/SessionInboxFile.swift`) records the sender kind `user` and the source session. Keep old inbox files readable (no kind means a session sender).
- The inbox scan at the next open delivers the file as a `.userMessage` with the header of the task that this task depends on.
- Update the doc comments at `:991` and `:1333`.

## Tests

- [x] To a recorded target: one inbox file with the kind `user` and the source session; the receipt is `sent`.
- [x] The scan at the next open delivers it as a user message with the header line.
- [x] A user message with no source session to a recorded target is still refused with `userNeedsLiveSessionReason`.
- [x] To an archived target: refused with the reason `archived`.
- [x] An inbox file of the old format still reads as a session message. #d199

## Review Findings (2026-11-18 08:53)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift:199` `reuse/reuse` — The new send(toRecorded:from:in:) is a near-match of the existing send(to:from:in:) at line 71 that was not extended. Both build the same OutgoingSessionMessage (from: .user(clientID:), text, sourceSession). The new helper differs only in calling directory.send instead of sendAndAwaitDelivery and in taking a ULID target. Parameterizing the await step, or reusing the existing helper, would avoid a parallel copy of the message construction. Generalize the existing send to take the target and an await flag (or a delivery closure), and call it from the recorded-target tests instead of defining send(toRecorded:from:in:).
- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectorySourceSessionTests.swift:214` `reuse/reuse` — The new awaitDelivery reimplements the existing awaitDelivery in RouterSessionDirectoryInboxTests instead of sharing it. Both loop over the same AsyncStream<SessionDirectoryEvent>.Iterator and match messageDelivered by id; only the return type differs (SessionMessage? here, Bool there). A fix to the wait logic must then be made in two places and the copies can drift apart. Move one awaitDelivery into a shared test helper (for example beside RouterSessionDirectory+SendAndAwaitDelivery.swift) that returns the delivered SessionMessage?, and have both suites call it; or make the Inbox version return the message and derive its Bool from it.