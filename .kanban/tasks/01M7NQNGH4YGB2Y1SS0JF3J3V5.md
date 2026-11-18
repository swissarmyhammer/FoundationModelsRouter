---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qk32ftrj1thsp5vm5bf9gw
  text: |-
    Research (implement step):
    - Today each delivery path ends in `hand(_:userHeader:to:ledger:)` (direct, inbox scan) or in `startAgent` + `launch`. Both put the mail in the queue (`session.mail`) and then call `keep(_:in:)`, which writes the ledger and sends `messageDelivered` AT ONCE. Thus a message to a working target (receipt `queued`) gives its event at queue time. Card test 3 ("not when it is queued") fails today.
    - `SessionMessage` of each path already has `sourceSession` (`Self.delivered`), also the scan path (^ty244es).
    - Order: the event goes out after `session.mail` returns. The pump of the target is a separate task (`arrival.start { mailDidArrive }`), and `keep` appends a line to `messages.jsonl` before the emit. Thus the first output of the answer can come before the event. No order guarantee today.
    - The session sends `SessionEvent.mailDelivered(id)` when the pump takes the mail; it is the first event of the answer, and each session event goes through one point: `RoutedSessionActor.emitSessionScopedEvent` (also `.cancelled`, `.lost`).
    - Decision: the directory sends `messageDelivered` when the target gets the message: a synchronous observer on the session, called in `emitSessionScopedEvent` before the session event goes to the output hub. The directory keeps each message that waits for its delivery under its registry lock (set before the put, so a fast pump cannot miss it). A `.cancelled`/`.lost` of the mail, or the unregistration of the session, drops it with no event. An `inbox(of:markRead: true)` read of a waiting message is also a delivery to the target (it never starts a turn), so the read sends the event and the take sends none. This matches D199 (f) "a working session gets the message when its turn ends", and the Extras text "the event comes when the target records the message".
    - Effect on tests: `sendAndAwaitDelivery` waited also for `queued` receipts; with the new rule a queued event comes only after the turn ends, so the helper waits only for `delivered` receipts.
  timestamp: 2026-11-18T15:06:03.642200+00:00
- actor: claude-code
  id: 01m7qkkzmdx8pka5st9527y4cr
  text: |-
    Implementation landed (not committed):
    - New `Sources/FoundationModelsRouter/Session/MailFate.swift`: `MailFate` (delivered / cancelledOrLost) and `RoutedSessionActor.observeMailFate(_:)` / `reportMailFate(of:)`. `emitSessionScopedEvent` calls the observer before the output hub gets the event.
    - `RouterSessionDirectory`: `Registry.awaitingDelivery`; `hand` sets the entry before `session.mail` (a fast pump cannot miss it) and removes it on refusal; `keep` no longer emits; `register` installs the observer; `unregister` and archive forget waiting entries; `inbox(of:markRead: true)` sends the event of a waiting message at the read; `startAgent` now goes through `hand`; `launch` no longer mails.
    - Test helper `sendAndAwaitDelivery` waits for `delivered` and `started` receipts only (a `queued` event comes when the held turn ends). `RouterSessionDirectoryInboxTests` no-watcher test now waits for the event with `nextDelivery(of:)` instead of a marker read right after the send.
    - New suite `RouterSessionDirectoryDeliveredEventTests` (8 tests). RED seen for "gives no event while it waits in the queue". The order test cannot fail deterministically on the old code (the old order was a race), so it passes on both; it is deterministic on the new code.
    - Card test 4 (inbox scan event keeps source session) is already covered by `RouterSessionDirectorySourceSessionTests.theNextOpenKeepsTheSourceSession`.
    - Follow-up note: the Extras doc of `SessionDirectoryEvent.messageDelivered` says "the directory put a message in the queue of the target, and the target recorded it"; it can add "when the target takes it".
  timestamp: 2026-11-18T15:15:17.773386+00:00
- actor: claude-code
  id: 01m7qkmjw5dt0pdvxjyfnhn218
  text: |-
    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Session/MailFate.swift (new), Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveredEventTests.swift (new, 8 tests), Tests/FoundationModelsRouterTests/Helpers/RouterSessionDirectory+SendAndAwaitDelivery.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryInboxTests.swift. Full `swift test`: 2906 tests in 337 suites passed, plus 48 and 19; 0 failures, 0 warnings in the package sources.
    - next: /review
  timestamp: 2026-11-18T15:15:37.477508+00:00
- actor: claude-code
  id: 01m7qm00384ebnzw6en2nyrs3h
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD` (d66a0cc4): 1 finding (1 confirmed, 1 refuted). Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveredEventTests.swift:182 (`test-integrity/no-test-cheating`).
    - hand check of the pump and cancellation invariants: no break found. `reportMailFate(of:)` is synchronous and adds no suspension point between a post and a take. The observer takes only the directory `state` Mutex for a short time, and no directory code calls the session while it holds that Mutex. Each `messageDelivered` event leaves `awaitingDelivery` under that Mutex, so a held, requeued or re-taken mail, or an inbox read and a take of the same mail, give one event only. A cancelled or lost mail removes its message with no event. The commit does not change the pump: it stays `Task.detached`.
    - tests: `swift test --filter 'RouterSessionDirectoryDeliveredEventTests|RouterSessionDirectorySourceSessionTests/theNextOpenKeepsTheSourceSession'`: 9 tests in 2 suites passed. Test boxes 1 to 4 are ticked. Box 5 (order) stays open because of the finding.
    - next: correct the order test so that it fails when the event comes after the first output, then run the review again.
  timestamp: 2026-11-18T15:21:51.464402+00:00
- actor: claude-code
  id: 01m7qm0henz33tscq44323g152
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — MailFate.swift (new), RoutedSessionActor.swift, RoutedSessionActorGeneration.swift, RouterSessionDirectory.swift, 3 test files
    - test: green — swift test in the implement step, 2906 tests in 337 suites (+48, +19), 0 failures
    - commit: d66a0cc4
    - review: findings — RouterSessionDirectoryDeliveredEventTests.swift:182 (the order test cannot fail). A check by hand of the pump and cancellation invariants found no break.
  timestamp: 2026-11-18T15:22:09.237764+00:00
- actor: claude-code
  id: 01m7qm9gqzxnh7e4wvtp6bm74g
  text: |-
    Fix of the order-test finding:
    - `theEventComesBeforeTheFirstOutput` now runs on a scripted backend whose first call holds on a latch (new helper `makeHeldFixture()`, which `startHeldTurn()` also uses). The test sends the message, waits until the held call has the prompt (`backend.changes`), emits the marker, and reads the event feed up to the marker. It opens the latch only after that. While the call holds, the model makes no output, so the event is in the feed up to the marker only when the directory sent it before each output of the model. The test has no sleep, no time limit and no retry.
    - The helper `firstOutput(of:in:)` had no other caller and is deleted.
    - What did not work: a check from two separate async streams (event feed and output feed) cannot see the order of two yields in the same synchronous job. No synchronous output hook exists, so the test uses the held model call as the point of order.
    - Limit: the test checks the order against the model output (text, answer). It cannot see the order of the `mailDelivered` session output and the directory event, because both yields happen in one synchronous call of `emitSessionScopedEvent`.
    - Proof of failure: a temporary change in `emitSessionScopedEvent` skipped `reportMailFate` for `.mailDelivered` and reported the delivered fate after the hub emitted a `.textDelta` or `.answered` with a mail origin. Result: the order test failed at `#expect(beforeTheModelOutput == [messageID])`, and the other 7 tests passed. The change was reverted (the source file is equal to HEAD).
  timestamp: 2026-11-18T15:27:03.423642+00:00
- actor: claude-code
  id: 01m7qm9rmw01rrpf7tygcnjjdy
  text: |-
    ### implement — changed
    - evidence: Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveredEventTests.swift (order test held on a latch; new `makeHeldFixture()`; dead `firstOutput(of:in:)` deleted). RED shown by a temporary change that sent the event after the first `.textDelta`/`.answered` output: the order test failed at `#expect(beforeTheModelOutput == [messageID])`, the other 7 passed. The change was reverted. `swift test --filter FoundationModelsRouterTests.RouterSessionDirectoryDeliveredEventTests`: 8 tests passed. Full `swift test` one time: 2906 tests in 337 suites passed, plus 48 in 26 and 19 in 3; 0 failures, exit 0. Finding flipped to [x], test box 5 ticked.
    - next: /review
  timestamp: 2026-11-18T15:27:11.516051+00:00
- actor: claude-code
  id: 01m7qmdd8hdv07fpsy0bq17785
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (198c3079): 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. The prior finding at RouterSessionDirectoryDeliveredEventTests.swift:182 is checked. The test reads the event feed up to the marker while the first model call holds on its latch, so an event that comes after the first model output gives an empty read, and the test fails. `swift test --filter RouterSessionDirectoryDeliveredEventTests`: 8 tests passed.
    - next: none. The task is in done.
  timestamp: 2026-11-18T15:29:10.929641+00:00
- actor: claude-code
  id: 01m7qmdx6f4xahdjnhj8qed45h
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — RouterSessionDirectoryDeliveredEventTests.swift (the order test holds the model call on a latch; a temporary late-event change made it fail, then it was reverted)
    - test: green — swift test in the implement step, 2906 tests in 337 suites (+48, +19), 0 failures
    - commit: 198c3079
    - review: clean — 0 findings; task in done
  timestamp: 2026-11-18T15:29:27.247998+00:00
depends_on:
- 01M7NQMW44Y418E9RB7HQM8P4M
- 01M7NQN675DJ1QW9MMPTY244ES
position_column: done
position_ordinal: ffffffffffae80
title: Put the source session in the messageDelivered event of each directory message (D199 (f), for ACPA-6)
---
## Goal

The host of the target session can show each delivered directory message in the transcript. FoundationModelsACPAgent uses this for ACPA-6 (`acpa-brief-at-sessions.md`). Brief: `../.briefs/at-sessions/router-brief-at-sessions.md`, item 3. Decision D199 (f).

## Depends on

FoundationModelsExtras task 01M7NQN30QZVJ438F3S3XNX0WV: `SessionMessage.sourceSession`. Extras adds NO new directory event. Use the event that exists: `SessionDirectoryEvent.messageDelivered(SessionMessage)`. `SessionMessage.to` has the target. Do not use `messageDelivered(_, to:)`.

## Current behavior

The Router already sends `messageDelivered` for each delivery (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`, doc comments at `:58`, `:997`, `:1021`, `:1154`, `:1223`, `:1332`, `:1353`, `:1400`). The `SessionMessage` in the event has no source session.

## Change

- In the `SessionMessage` of each `messageDelivered` event, set `sourceSession` for a user sender that has a source session. A session sender keeps its sender session as today.
- Make sure that each delivery path sends the event with the correct fields: a direct delivery to a live idle target, a queued delivery when the turn ends, the inbox scan of a recorded target, and a message that starts an agent session.
- Make sure that the event comes before the turn of the message starts, so that the host can show the message before the chunks of its turn. If the order is not correct today, correct it.

## Tests

- [x] A user message with a source session gives one `messageDelivered` event with the sender `user`, the source session, the target (`to`) and the text.
- [x] A session message gives one event with the sender session, the target and the text.
- [x] A queued message gives its event when it is delivered, not when it is queued.
- [x] A user message from the inbox scan gives its event with the source session.
- [x] The event comes before the first output of the turn of the message.

#d199

## Review Findings (2026-11-18 09:16)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/RouterSessionDirectoryDeliveredEventTests.swift:182` `test-integrity/no-test-cheating` — The test named theEventComesBeforeTheFirstOutput does not prove the order it names. It waits for the first output (line 179), emits the marker (line 180), and then reads the event feed up to the marker (line 182). An event that the directory sends after the first output, but before the marker, still passes. The test cannot fail for the defect its doc comment names (an event sent after the session took the mail). Check the order at the moment the first output arrives. For example, read the event feed up to the marker before awaiting the output, or record the event and output positions in one shared sequence and assert that the event position is lower. Then the test fails when the event comes after the first output.
