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
depends_on:
- 01M39ZP766H4S63AR4R44Y6BA4
- 01M3A1F89ZRFMCGTNPBNJDP02P
position_column: todo
position_ordinal: '8e80'
title: Rename the "turn" level to "request" in the Router API, events, and code
---
## Why

The word "turn" hides the real units. The Router has three levels:

1. **Request**: one call from the caller to `respond`/`stream`, one prompt in, one reply out. Now named "turn".
2. **Attempt**: one `LanguageModelSession.respond` inside a request (`runTurnAttempt`). More than one after an overflow retry or a compaction continuation.
3. **Pass**: one executor call, one generation. The item of the per-model queue.

The user decided on 2026-09-24 that breaking consumers is acceptable. The consumers are our own packages.

## What to do

1. Rename the request level. Suggested names (the implementer can propose better names in a comment first):
   - `turnLock` → `requestLock`; `beginTurn`/`endTurn` → `beginRequest`/`endRequest`.
   - `TurnID` → `RequestID`; `currentTurnId`, `lastTurnId`, `cancelRequestedTurnId`, `isTurnCancelled` to match.
   - `cancelCurrentTurn()` → `cancelCurrentRequest()`; `TurnCancellationResult` (`.noTurnInFlight`, `.turnCancelled`) to match.
   - `TurnStart`, `TurnOutcome`, `SessionProjection.currentTurn`, `SessionReentryError.sameSessionTurnInFlight`, `isInsideOwnTurnToolCall`, `forkDuringSameSessionTurn`.
   - `TurnBoundaryTool.turnWillBegin()` → `requestWillBegin()`.
   - `awaitingUser(_:)`: ^44y6ba4 makes it a pass-through. Decide here if it stays (renamed) or goes.
2. Fix the meaning of the events. `SessionEvent.turnEnded` is sent one time for each ATTEMPT (see its doc comment in `Session/SessionEvent.swift`), and a request that retries sends two. Choose one:
   (a) `requestStarted` / `requestEnded`, one pair for each request, and a separate `attemptEnded(TokenUsage)` for each attempt; or
   (b) rename to `attemptStarted` / `attemptEnded` and add request events.
   Write the choice AND the final list of old name → new name in a comment on this task BEFORE the change. The FoundationModelsACPAgent card ^tz867gz (on the ACP board) reads that comment.
3. Recording format: the recorded files hold turn-level data (`TranscriptEvent.isFailedTurnClose` in `Recording/TranscriptEvent.swift`; the turn-final `.response` usage stamp read by the stamp reader in `Compaction/TokenBudget.swift`). Rename the Swift API. The reader must still read files written before the rename. Do not change the key names on disk unless a version bump and a reader for the old version come in the same change.
4. Update the doc comments, `plan.md`, `generation-queue.md`, the tracing attribute names (`Tracing/RouterTracing.swift`), and the test names.
5. Update these consumers in the same change set (counts of the old symbols, measured 2026-09-24 with `rg`):
   - `../FoundationModelsMultitool`: turnWillBegin 28, TurnBoundaryTool 3, turnEnded 3, turnStarted 2, cancelCurrentTurn 1.
   - `../AgentViewKit`: cancelCurrentTurn 11, turnEnded 10, turnStarted 6, TurnStart, TurnID.
   - `../FoundationModelsExtras`: TurnOutcome 1.
   - `../FoundationModelsAgents`: turnStarted 1.
   Before you edit one of these, read its board. If its board says that it adopts the rename itself (as FoundationModelsACPAgent does), do not edit it; list it in a comment here.
6. Do NOT edit `../FoundationModelsACPAgent` (user decision, 2026-09-24, from the ACP session's comment on this task). It adopts the rename on its own board, card ^tz867gz. It has 39 `turnEnded`, 12 `awaitingUser`, 9 `turnStarted`, 6 `cancelCurrentTurn`, 3 `turnWillBegin`, and one each of `TurnStart`, `TurnOutcome`, `turnCancelled`, `noTurnInFlight`.

## Acceptance Criteria

- [ ] No public symbol of the Router names "turn" for the request level (`rg -n "\b[A-Za-z]*[Tt]urn[A-Z]" Sources` shows only recording keys kept for old files and `modelTurnsThinkingOffByTemplateFlag`).
- [ ] The request events come one time for each request, also when the request retries (test with an overflow retry).
- [ ] A recording written before the rename still loads (test with a fixture file).
- [ ] A comment on this task gives the event choice and the full old → new name list, before the change lands.
- [ ] The Router suite builds and passes, and each consumer this task edits (step 5) builds and passes its suite. FoundationModelsACPAgent is not edited. #generation-queue #naming