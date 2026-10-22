---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5jq7a28qntxsq1wf4fgfmms
  text: 'Research: send() in RouterSessionDirectory resolves the address (SessionAddressResolution, pure) then delivers; every message got chainDepth firstChainDepth=1. OriginContext.current (task-local, Session/SessionOutput.swift) is bound by the pump to .mail(batch ids) and the submission re-binds it on the model-call worker; ToolContext.current is bound for tool bodies the same way. The depth source is the SENDER''s own ledger: the mail ids of its turn are the ids of messages delivered to it. Extras InMemorySessionDirectory (+LoopGuards, +Messages, +Refusal) is the reference double: length check first, then countSend, then chain-depth check, refused receipts with no target; tag targets beyond the limit refused with their target. ScriptedToolCallingModel counts rounds over the whole transcript, so it cannot make a second turn call a tool; the per-turn test needs a model that plays one round per turn (counts .toolCalls after the last .prompt). PumpProbeContainer shares one backend across sessions, so the no-cap test needs a container that vends one held PumpProbeBackend per session.'
  timestamp: 2026-10-22T21:10:40.968855+00:00
- actor: claude-code
  id: 01m5jqzb0fscn3ctddfv392vhy
  text: |-
    Implementation landed. send() captures OriginContext.current before its first await; the task-local does reach the directory from inside a tool call (the chain test proves it for the first tool call of each turn, so no ToolContext turn-token fallback was needed). Order in send: length check (UTF-8 bytes, throws messageTooLong) -> resolve (unknownSession still throws first) -> chain depth from the sender's own ledger -> per-turn count (keyed by the turn's mail-id set; a set that shares an id with the last counted turn is the same turn, so mail that joins mid-turn cannot reset the count; UI senders and sends outside a turn are not counted) -> chain-depth refusal -> deliver, where a multi-target (tag) delivery delivers the first maxTagTargets and refuses the rest with their target. Guard refusals carry no target, as the Extras InMemorySessionDirectory double does. Fixture notes: ScriptedRoundsModel gained replaysEachTurn (counts .toolCalls after the last .prompt) because ScriptedToolCallingModel cannot make a second turn call a tool; each call of a round carries its own text so no two consecutive calls are identical. The no-cap test passed on its first run: there is no slot limit in Router, so it is a regression guard (a capped directory would hang at the working wait, documented as Rule T1 quiet state). TDD note: the length/per-turn/tag code was first written ahead of its tests; it was deleted, the tests were run red (length not thrown, 3 of 3 sends delivered, 10 of 10 tag targets delivered), then re-added green. Build prints a SwiftPM "missing creator for mutated node" warning for the mlx-swift_Cmlx.bundle dependency path; not from this change's sources (not checked against clean main).

    ### implement — changed
    - evidence: swift build --build-tests clean of compiler warnings; swift test: 2161 tests in 265 suites passed (9 known issues, pre-existing withKnownIssue), plus 39 and 19 test runs passed; new suites SessionMessageLoopGuardTests (6 tests) and RouterSessionDirectoryNoCapTests (1 test) green. Files: Sources/FoundationModelsRouter/Directory/SessionMessageLimits.swift (new), Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/Helpers/DirectorySendTool.swift (new), Tests/FoundationModelsRouterTests/Helpers/ScriptedRoundsModel.swift, Tests/FoundationModelsRouterTests/SessionMessageLoopGuardTests.swift (new), Tests/FoundationModelsRouterTests/RouterSessionDirectoryNoCapTests.swift (new)
    - next: /review
  timestamp: 2026-10-22T21:23:48.367517+00:00
depends_on:
- 01M5F3PESH74WZB1EDN6KQ5BQD
position_column: doing
position_ordinal: '80'
title: 'ROUTER-5: Loop guards (chain depth 3, 16 sends per turn, 8 tag targets, 16 KB) and no cap on working sessions'
---
## Goal
The directory applies the loop guards to every send, for a session sender and a UI sender alike, so the `sessions` tool and the `sessions` graph get the same rules; and many sessions work at the same time with no slot limit.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-5-message-delivery-and-loop-guards (the loop guards; "no limit on the number of sessions")
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.7 (the guard table)
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md sections 10.3 and 13.3; TestudoApp decision D72 (e)

## What
- New `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/SessionMessageLimits.swift`: `public struct SessionMessageLimits: Sendable, Equatable` with `maxChainDepth = 3`, `maxSendsPerTurn = 16`, `maxTagTargets = 8`, `maxMessageBytes = 16 * 1024` (UTF-8 bytes). `RouterSessionDirectory` takes it in `init` with the defaults, so tests can lower them.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift`:
  - **Chain depth, read with no race.** Do not take the sender's turn from the async ROUTER-9 feed: a send made by the first tool call of a turn can reach the directory before the feed has seen that turn. Read the turn where the send runs: the `send` call is made inside the sender's tool call, so the task-local `OriginContext.current` (`Session/SessionOutput.swift`, an `Origin.mail(Set<MailID>)` from Extras `Mail/Origin.swift`) is in scope across the `await` into the directory actor. Capture it at the top of `send`. If it is not `.mail` (a send from outside a turn), the turn has no message. The depth of a message that a session sends = 1 + the largest ledger depth among those mail ids; 1 when none of them is a directory message (a user turn). If the task-local turns out not to reach the directory (for example the Multitool tool hops to a detached task), stop and ask; the fallback is a turn token that `ToolContext` carries. A UI message has depth 1. A send whose depth is above `maxChainDepth` gives a `refused` receipt with a reason that names the limit. (The Extras error list has `chainTooDeep(limit:)`, but the spec text says the send is refused; the receipt is the plan, see the plan questions.)
  - **Sends from one turn.** Count the sends of each session keyed by the captured turn (the mail-id set of `OriginContext.current`), so a new turn starts a new count with no race; the 17th and later give `refused`. A UI sender has no turn, so this guard does not apply to it.
  - **Targets of one tag send.** The first 8 targets get the message; each other target gets `refused` with a reason that names the limit.
  - **Length.** A text longer than `maxMessageBytes` throws `SessionDirectoryError.messageTooLong(limit:)` before any delivery. This also keeps each `messageDelivered` event under the limit (event rule 5).
  - The depth is stored on the `SessionMessage` (`chainDepth`) in the ledger.
- No change makes a start or a delivery wait for a free slot.
- Test fixture: Router has no `sessions` tool (that is MT-2 in Multitool), so add `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/Helpers/DirectorySendTool.swift`, a test tool that calls `directory.send` with `from: .session(ToolContext.current!.sessionID)` from inside a turn, scripted by the scripted models.

## Subtasks
- [x] Failing test first: with `DirectorySendTool`, A sends to B (depth 1), B's turn sends to C (depth 2), C's turn to D (depth 3), D's turn to E is `refused` (depth 4); each send is the first tool call of its turn (proves no race with the feed).
- [x] Add `SessionMessageLimits` and the length check (`messageTooLong`) for a session sender and a UI sender.
- [x] Per-turn count: with a lowered limit of 2, the third send of one turn is refused, and a new turn of the same session can send again.
- [x] Tag cap and UI sender: 10 sessions with one tag, a tag send gives 8 non-refused receipts and 2 refused, for a session sender and for a UI sender; a UI message has depth 1 in the ledger.
- [x] No cap: with a held scripted model, start 6 sessions through the fake launcher; all 6 summaries show `working` at the same time, every receipt is `started` or `delivered` (none `queued`), and all answer after release.

## Acceptance Criteria
- [x] A send above the chain depth is `refused`, also when it is the first tool call of the turn; the depth of each message is in its ledger record.
- [x] The 17th send of one turn is `refused` (16 is the default; the test may lower it).
- [x] A tag send to more than 8 targets refuses the rest, for both sender kinds; a UI message has depth 1.
- [x] A text over 16 KB throws `messageTooLong(limit: 16384)` for both sender kinds.
- [x] Six sessions show `working` at once, and no receipt is `queued`.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionMessageLoopGuardTests.swift` (with `Helpers/DirectorySendTool.swift`)
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterSessionDirectoryNoCapTests.swift`
- [x] `swift test --filter "SessionMessageLoopGuard|RouterSessionDirectoryNoCap"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #mail #limits