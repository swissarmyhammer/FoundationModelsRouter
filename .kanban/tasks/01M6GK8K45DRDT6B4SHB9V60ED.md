---
comments:
- actor: claude-code
  id: 01m6gt767a1ejem69my7c853g4
  text: |-
    DESIGN (no code written yet). Depends on the write-ahead card 01M6GK7RHHHC6B6QMJ25FT1QDT and on the public `RunKey` and `runStatuses` of 01M6GQS8VRYA1BC5D167EYYRRY.

    1. Finding the keys: `runStatuses(of:)` from the lookup card. The host claims a key with status `.orphaned`. No second scan API.
    2. Claim at restore: add `claimingRuns: Set<RunKey> = []` to `restoreSession` and `restoreSessionTree`. A claim is a parameter of one restore (not a two step call), because the lost events are posted inside the restore (SessionTreeRestoration.swift:498) and a later call is too late. The claim applies to the node that owns the run (the parent). `lostRunTerminalEvents` takes `excluding: Set<RunKey>`. A claimed key that is not an orphan (completed, or unknown) is an error: `SessionTreeRestorationError.runNotClaimable(RunKey)`. No silent no-op.
    3. The claimed runs are kept in the restored session as OPEN CLAIMS (a set in the session actor; the run counts as work until it ends, so `awaitIdle` does not report idle while a claim is open; CHECK this against how the run plane counts work).
    4. Completion: a new method on the session, `completeClaimedRun(_ key: RunKey, outcome: OperationOutcome, detail: String?) async -> Bool`. It posts one `.completed` through the outbox (journaled, and a run mail as for any run). It returns `false` and posts nothing for a key that is not an open claim or is closed already. Duplicate terminal rule: a key leaves the open claims on its first terminal, so a second call is a no-op. This is the only duplicate rule needed; I do not change the general outbox for other runs.
    5. Never completed: `close()` posts `.completed` with outcome `.lost` for each open claim (same detail rule as `lostDetail(of:)`) before the outbox closes, so no run stays open. A crash before that leaves the key orphaned again, and the next restore may claim it again.
    6. Pairing with the write-ahead card: a claimed key must have an open call in the transcript (the `.toolCallStarted` entry of that card). A claim for a run with no open call is allowed (the run may have posted events and no call); the host is told by the report. CHECK `ToolCallOutputPairing` for how an output matches by call id and correlationID.
    7. No claim = today's behavior.

    Tests (`ClaimOrphanRunsTests`): claim and complete once; second complete is a no-op; claim and close gives lost; no claim gives lost as today; claim of a completed key throws; awaitIdle with open claim.
  timestamp: 2026-11-03T13:40:15.722041+00:00
depends_on:
- 01M6GK7RHHHC6B6QMJ25FT1QDT
position_column: todo
position_ordinal: '8280'
title: Let a host claim orphan runs at restore, so the restore does not post lost and the host can post the real completed
---
## What
When the process stops during a tool run, the restore marks the run as lost. For nested sub-agent sessions the host (FoundationModelsACPAgent) wants to re-drive the interrupted sub-agent and let its real result complete the ORIGINAL run (same tool, same correlationID) of its caller. (User, 2026-11-03.) The restore must let the host claim such runs.

Facts (from the Router session, 2026-11-03):
- `Recording/SessionTreeRestoration.swift:493-499` calls `TranscriptTree.lostRunTerminalEvents(in:)` (static, near line 746) unconditionally over the effective events of each node, and posts each `.lost` to the new outbox. An orphan is a `RunKey(tool, correlationID)` with a non-terminal event and no `.completed` (`OrphanRunScan`, near line 700). Nothing lets a host skip it.
- A later real `.completed` for the same pair would be a second terminal for that run, after the `.lost` was journaled. How the outbox treats that was not checked.
- Possible shape (NOT designed, NOT decided; the Router session designs it): a restore parameter such as `claimingRuns: Set<RunKey>` that removes those keys from the lost scan, plus a host contract: the host posts a `.completed` for each claimed key, or a lost one when the session closes. Without a claim, behavior stays as today.

Do (design first; write the design in a task comment and discuss it with the user before the code):
1. Decide the API (restore parameter, or a two step claim) and the contract for a claimed run that the host never completes (the close must end it as lost, so no run stays open for ever).
2. Decide how the host finds the orphan keys before the restore (a read-only scan API, or a report in the restore result), so the host knows what it can claim.
3. Define the outbox rule for a `.completed` that comes after a restore for a claimed key, and for a duplicate terminal.
4. Pair with the write-ahead card (`01M6GK7RHHHC6B6QMJ25FT1QDT`): a claimed run must pair with its open `.toolCalls` entry in the transcript.

Consumer: FoundationModelsACPAgent board, tag `subagents`, task "Re-drive interrupted nested runs after a cold resume" (`01M6GK6AX0RWQ1PDT89GC0991F`).

## Acceptance Criteria
- [ ] A restore with a claim posts no `.lost` for the claimed keys and posts `.lost` for each other orphan, as before.
- [ ] A host can read the orphan keys of a recorded tree before it restores.
- [ ] A later `.completed` for a claimed key is journaled once, and the run is complete once.
- [ ] A claimed run that the host never completes ends as `.lost` when the session closes.
- [ ] A restore with no claim behaves as today.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ClaimOrphanRunsTests.swift`: claim and complete, claim and close, no claim, duplicate terminal, key scan.
- [ ] Run `swift test --filter ClaimOrphanRunsTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents