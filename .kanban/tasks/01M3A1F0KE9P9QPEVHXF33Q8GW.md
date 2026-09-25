---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3a3nymrdd81rbzjcytnee5w
  text: 'Consumer note from FoundationModelsACPAgent (2026-09-24, user decision): the Router agent works only in the Router. Do NOT edit ../FoundationModelsACPAgent in this change set. The ACP agent adopts the rename on its own board (card ^tz867gz there). Step 5 still applies to the other consumers unless their boards say the same. Please write the final event choice (a) or (b) and the new names in a comment here: the ACP card reads them.'
  timestamp: 2026-09-24T16:23:50.168869+00:00
- actor: claude-code
  id: 01m3cw3692jndf9sgkvnnq9ffg
  text: '2026-09-25, from the user (answer to a question during ^44y6ba4): "i just wanted you to eliminate this ''turn'' concept as i think it is confusing". Remove the word "turn" from the Router API, events, errors and code names (for example `sameSessionTurnInFlight`, `forkDuringSameSessionTurn`, `turnLock`, `SessionEvent` turn cases). Decide the new names yourself; the user does not want to choose API names. Write each rename on this task.'
  timestamp: 2026-09-25T18:08:58.658139+00:00
- actor: claude-code
  id: 01m3cwy7na6bt6aet4g0xe5dcq
  text: |-
    Work stopped on 2026-09-25 by a change of direction from the user: "it's not just removal of the word 'turn' -- it's the concept that is problematic, as opposed to a queue of requests to the Foundation level model to do generation or tool calling." A pure rename to "request" is thus probably not the correct change. No rename was made. The tree stays as it is.

    Files changed so far:
    1. `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/session.json` (new, untracked). A recording that the code at HEAD 50a629e wrote. It holds the on-disk key `recoveriesPerTurn` (from `RepetitionDetection`), and the working directory is the neutral `/fixture-work`.
    2. `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/transcript.jsonl` (new, untracked). Six events: session, prompt "first", a stamped `.response` (100 in, 50 out), a `generationCall`, prompt "second", and the failed close (`.response`, empty segments, 0 in, 0 out). It was made for the acceptance criterion "a recording written before the rename still loads". No test reads it yet, and `Package.swift` does not yet declare it as a resource. If the new direction needs no such fixture, delete the directory.
    3. `Tests/FoundationModelsRouterTests/TokenUsageMeteringTests.swift`: a temporary test wrote the fixture and was then removed. The net diff is empty (`git status` shows no change).
    4. `.kanban/tasks/01M3A1F0KE9P9QPEVHXF33Q8GW.*`: the task moved to `doing`, plus these comments.

    Research results for the next agent:
    - The only key with "turn" on disk is `recoveriesPerTurn` in `session.json` (synthesized `Codable` of `RepetitionDetection`). `TranscriptEvent` JSON has no "turn" key; `isFailedTurnClose` and `turnUsageStamp` are computed, not stored.
    - `SessionEvent.turnEnded` is sent in `finishTurn` (`RoutedSessionActorRecording.swift`), one time for each attempt. `finishTurn`, `finishTurnAndRequeueIfUnattached`, `recordFailedTurn`, `isFailedTurnClose`, and `turnUsageStamp` are attempt level, not request level.
    - `turnStarted` is sent one time for each request in `runTurnWork` (`RoutedSessionActorTurnExecution.swift`). There is no request-end event.
    - The consumers FoundationModelsMultitool, AgentViewKit, and FoundationModelsAgents depend on the Router through a git URL at `branch: "main"`. Their builds do not see a local Router change unless `swift package edit` is used. Only FoundationModelsACPAgent's board (card ^tz867gz) says that it adopts the change itself.
    - The Router holds about 5500 "turn" words in about 250 files. Some are not the request level: verbs ("turns reasoning off", "turned off"), chat-template terms ("assistant turn"), and `modelTurnsThinkingOffByTemplateFlag`.
  timestamp: 2026-09-25T18:23:44.810891+00:00
- actor: claude-code
  id: 01m3cxkwnp3a3ks0rhrm41z3r0
  text: '2026-09-25: STOPPED and superseded in scope. The user wants a work-queue design with no locks and no "turn" concept, not a rename to "request". The design task ^jdp02p now designs the new model and writes the implementation tasks. This task waits on ^jdp02p; the design either replaces it with new tasks or rewrites it. Do not start the rename. The untracked fixture `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/` (a recording written at 50a629e with the key `recoveriesPerTurn`) can serve the "old recordings still load" test.'
  timestamp: 2026-09-25T18:35:34.454106+00:00
- actor: claude-code
  id: 01m3cyxmhec7kz764gew9cbc1x
  text: 'Rewritten on 2026-09-25 by the design task ^jdp02p (not deleted). The old plan (rename "turn" to "request", keep `turnLock` as `requestLock`) is dropped: the user rejected a rename and a lock. The new tasks remove the turn itself: ^a0ze9af, ^1psqdm9, ^dpn2ytt, ^3qx0mpt, ^cbhpdjy, ^x7cxsg3, ^5d0qx1b. This task now removes what they leave: `TurnBoundaryTool` becomes `SubmissionBoundaryTool.submissionWillBegin()`, `awaitingUser(_:)` goes, and the other "turn" names and docs go. The consumer updates moved to ^d7d777f. The event choice that the ACP card ^tz867gz asked for is in `generation-queue.md` section 5.6: `submissionStarted`/`submissionEnded` for each SDK call (`submissionEnded` replaces `turnEnded` one for one), and `answered`/`answerFailed` for each final answer. The full old name to new name list is in section 5.6, and ^d7d777f posts it on ^tz867gz.'
  timestamp: 2026-09-25T18:58:22.382444+00:00
depends_on:
- 01M3CYMT8QK7YBJ904JX7CXSG3
- 01M3CYN72XRWG9THXXE5D0QX1B
position_column: todo
position_ordinal: '8e80'
title: 'Remove the last "turn" names: the boundary tool, awaitingUser, the tracing names and the docs'
---
## Why

Rewritten on 2026-09-25 by the design task ^jdp02p. The earlier plan of this task renamed "turn" to "request". The user rejected that: "A rename of 'turn' to 'request' is NOT the goal"; the "turn" concept is vague and must go, "as opposed to a queue of requests to the Foundation level model to do generation or tool calling". The work-queue tasks remove the turn itself: ^a0ze9af (the worker), ^1psqdm9 (the submission is the item), ^dpn2ytt (reads and forks with no lock), ^3qx0mpt (the pump, no `turnLock`), ^cbhpdjy (the message API), ^x7cxsg3 (the events and `SessionAnswer`), ^5d0qx1b (the limits for each answer and the stored key). This task removes what is left. Design: `generation-queue.md`, sections 5.6 and 5.10.

## What to do

1. Replace `TurnBoundaryTool.turnWillBegin()` with `SubmissionBoundaryTool.submissionWillBegin()`. The session calls it one time before each submission of the pump, after it takes the messages, at the same place as now (after the drain, before the model call).
2. Remove `awaitingUser(_:)` from `RoutedSession`. It is a pass-through since ^93kjn94. A wait for a person in an in-band tool holds the model for every session on it. The way to wait for a person is an elicitation from a background run (`SessionEvent.elicitationRequested`, `respond(elicitationId:response:)`).
3. Rename every other Swift name with "turn" at the request level that the earlier tasks left: for example `recordFailedTurn`, `runTurnAttempt`, `currentTurnEventSink`, `turnEventSink`, `settledRunDeliveryPrompt` docs, `RouterTracing.TurnEntryPoint`, `modelTurnCount` in test helpers, and the "turn" wording in doc comments, `plan.md` and `generation-queue.md`. Keep the recording keys on disk as ^5d0qx1b decided.
4. Update the test names and the suite names that say "turn".

## Acceptance Criteria

- [ ] `rg -n "\b[A-Za-z]*[Tt]urn[A-Z]" Sources` shows only recording keys kept for old files and `modelTurnsThinkingOffByTemplateFlag`.
- [ ] `rg -n -i "\bturns?\b" Sources` shows no doc comment that names a request-level "turn".
- [ ] A test: `submissionWillBegin()` is called one time before each submission of the pump, also for a submission that mail started.
- [ ] Public-surface tests for `SubmissionBoundaryTool`.
- [ ] Full `swift test` green, 0 new warnings; IntegrationTests build clean. #generation-queue #naming