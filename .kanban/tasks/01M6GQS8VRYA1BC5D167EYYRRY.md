---
comments:
- actor: claude-code
  id: 01m6gt6qrsjx58xqw87dvsek2w
  text: |-
    DESIGN (no code written yet).

    1. Child listing. `SessionSummary` gets `parentToolCallId: String?` (from `record.agentSpawn?.parentToolCallId`; `nil` for a root). `RecordedSessions.summary(of:)` fills it (Directory/RecordedSessions.swift:60). `RouterSessionDirectory` gets `recordedChildren(of parent: ULID) throws -> [SessionSummary]`: the recorded summaries with `kind == .subagent` and `parentID == parent`. It reads `index.md` files only; it restores nothing and has no side effect. The summary already shows `agentID`, `agentName` and (with the ended card 01M6GPT1DM4KZNTT31NMQ0962J) `endedAt` and `endReason`. A child that wrote no journal event is found here and not by the scan.

    2. Run status. Make `RunKey(tool:correlationID:)` public (today it is private in SessionTreeRestoration.swift:693). Add:

        public enum RunStatus: Sendable, Equatable { case orphaned; case completed(OperationOutcome) }
        RouterSessionDirectory.runStatuses(of session: ULID) throws -> [RunKey: RunStatus]

    It returns one entry for EVERY run key that has a journal event in the effective events of that session: `.completed(outcome)` when a `.completed` exists, `.orphaned` otherwise. It uses the same `OrphanRunScan` as the restore (`lostRunTerminalEvents`, line 746 becomes a thin wrapper over the scan), so the orphan set is the set the restore marks lost, by construction. It restores nothing and posts nothing. Reason for all keys, not only orphans (coordinator note): if the host crashes after the child result was journaled as `.completed` in the parent but before `markEnded`, the child looks unended.

    3. Host rule: restore a child only if it is unended (`endedAt == nil`) AND the run with `RunKey(agentsTool, child.parentToolCallId)` in the parent is not `.completed`. A host may also call `markEnded` for the second case, as repair.

    4. No restore behavior changes.

    5. The three facts to verify (they are tests, written first, in `RecordedChildLookupTests`, and the result goes in a comment): (a) the tool name the journal records for the `agents` tool; (b) a spawn child with `agentSpawn` and no fork parent restores as a root: `restoreSessionTree` needs `parentId == nil` (line 265), and `parentId` comes from directory nesting (TranscriptTree.swift ~185-212), so I expect yes; (c) the orphan `correlationID` equals `parentToolCallId`. If (b) fails, the fix is a separate decision for the user.

    Tests: finished child, interrupted child, child with no journal event; listing; status map equals the restore's lost set; completed-but-unended child; no side effect (folder bytes unchanged).
  timestamp: 2026-11-03T13:40:00.921590+00:00
- actor: claude-code
  id: 01m6gxrm77znn3r975vzzjgfr4
  text: 'DESIGN CHANGE (coordinator, 2026-11-03). `SessionSummary` belongs to FoundationModelsExtras, so point 1 of the design changes: do NOT add `parentToolCallId` to `SessionSummary`. Add a Router-owned public value type `RecordedChild` (Sendable, Equatable) with `sessionID`, `agentID`, `agentName`, `parentSessionId`, `parentToolCallId` and `ended: SessionEndedMarker?` (the type of the ended marker card). `RouterSessionDirectory.recordedChildren(of parent: ULID) throws -> [RecordedChild]` reads the `index.md` records only. It must find a child whose folder sits inside its parent folder too (the ended marker card found that `unendedChildren(of:)` does not see such a child; check the folder layout and use the tree loader if needed). `runStatuses(of:)` and the host rule stay as designed.'
  timestamp: 2026-11-03T14:42:12.839936+00:00
- actor: claude-code
  id: 01m6gzs4tar7vp2fpg0t5d6sam
  text: |-
    ### implement — changed
    RESULT of the three facts (real tests in RecordedChildLookupTests; a parent session runs the real `agents` OperationTool of AgentOperationFixtures, a crash leaves it open, a new router reads it):
    (a) The journal records the runs of the agents tool under the tool name "agents". The mount posts the pending envelope as a `.progress` event with tool = the name of the OperationTool. Test: theJournalRecordsTheAgentsToolName. PASS.
    (b) A spawn child (agentSpawn set, no fork parent) restores as a root with restoreSession(id:recordingRoot:). Test: aSpawnChildRestoresAsARoot. PASS. No change to restore was needed.
    (c) The orphan correlationID equals the completion token in the pending envelope. A child that the host spawns with this token as parentToolCallId has parentToolCallId == orphan correlationID. Test: theOrphanCorrelationIDEqualsTheParentToolCallID. PASS. Note: the test sets parentToolCallId itself from the envelope token, as the Agents host must. The Agents package was not run here.

    DONE: public RunKey, RunStatus (orphaned, completed(OperationOutcome)), RecordedChild; RouterSessionDirectory.recordedChildren(of:) and runStatuses(of:). Both only read. OrphanRunScan (new file Recording/OrphanRunScan.swift) is shared by the restore (lostRunTerminalEvents is now a thin wrapper) and by runStatuses, so the orphan set equals the restore lost set; a test compares both. recordedChildren finds a child whose folder sits inside its parent folder (test aNestedChildIsListed): it reads every index.md at any depth (RecordedSessions.nestedRecords), not only direct entries of a root. SessionSummary was not changed. No restore behavior change.
    Tests: 13 in RecordedChildLookupTests pass; full swift test passes (2251 tests in 275 suites).

    UNDECIDED: (1) A `.completed` event with no outcome maps to `.completed(.other("missing"))`; the journal should never write one. (2) runStatuses loads the whole tree of each recording root to find the session (same cost as a restore load) and throws on a corrupt tree. (3) A nested child cannot be restored as a root (parentId is set by folder nesting); only listing is supported for it.
  timestamp: 2026-11-03T15:17:26.986359+00:00
- actor: claude-code
  id: 01m6h0f1k1mcpavt0bxrwgzzqq
  text: |-
    ### implement - changed (rework: scope of runStatuses(of:))
    Coordinator request done. runStatuses(of:) no longer loads the whole tree of the recording root. It does this:
    1. TranscriptTree.sessionFolder(of:under:) lists the file names under the root and finds the folder of the session at any depth. It reads no index.md and no transcript. Two folders with the same id throw duplicateSessionId, as the full load did.
    2. TranscriptTree.loadChain(ofSessionIn:under:) reads only the chain: the session and each session folder it nests under (the fork chain). The effective events use the same code as before, so the result is the same as on the full tree. No sibling, child or other session is read.
    3. The scan (OrphanRunScan) is unchanged. Restore behavior is unchanged (TranscriptTree.load and the restore code were not touched).
    Typed errors: no new case was needed. A damaged chain throws TranscriptTreeError (indexUnreadable, indexMissing, forkCutPointMissing, duplicateSessionId), RecordingSchemaVersionError (newer router), or JSONLFileError.readFailed (transcript that does not read). A damaged record of ANOTHER session no longer fails the call, so a host can map the typed error to "unknown" for the affected child and still resume the root. This is in the doc comment of runStatuses(of:).
    Tests added in RecordedChildLookupTests (RED first): a damaged sibling session does not fail the read (failed before, indexUnreadable); a damaged sibling fork does not fail the read of a fork (failed before); a fork holds the runs of its parent; a damaged index of the session throws indexUnreadable; a damaged index of the parent of a fork throws indexUnreadable (these three passed before, they pin the behavior). The orphan-set-equals-restore test is kept.
    Full swift test: 2261 tests in 276 suites passed, no warnings from the change.
    UNDECIDED: (1) A nested spawn child (folder inside the folder of its parent, no fork cut) still throws forkCutPointMissing in runStatuses, as before. (2) recordedChildren(of:) still reads every index.md under the roots (the card asks for a listing; the request covered runStatuses only).
  timestamp: 2026-11-03T15:29:24.577467+00:00
- actor: claude-code
  id: 01m6h1zxkr8gbn8bh6jy6ygprh
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD, 1 finding on this card: RecordedSessions.swift:59
    - next: fix the finding, then review again
  timestamp: 2026-11-03T15:56:06.136137+00:00
position_column: review
position_ordinal: '8280'
title: Public read-only lookup of recorded child sessions and public orphan scan, without restoring the parent
---
## What
The host must find the sub-agent sessions to restore after a crash, and the runs that were interrupted. The Agents session found that the Router gives it no public way to do either (read in the code, not run; paths under `Sources/FoundationModelsRouter`):
- The tree is reachable by session id only. Finding recorded children of a parent by `agentSpawn.parentToolCallId` (the completion token of the call that started them) needs a public listing of records with that field. `transcriptTree` is not public, and the recorded session listing (`Directory/RecordedSessions.swift`, `SessionSummary`) shows `kind` and `parentID`, but I did not confirm that it shows the parent tool call id.
- Orphan runs are manufactured only while the PARENT session is restored (`Recording/SessionTreeRestoration.swift`, near lines 493 to 499), and `TranscriptTree.lostRunTerminalEvents(in:)` (near line 746) is internal and static. A host that wants to read the orphan set before the restore, or without restoring the parent, has no API.
- A child whose run never wrote a journal event (it stopped before its first `.progress`, `.elicitation` or `.message`) gives no orphan, so the orphan scan alone cannot find it. The listing of recorded children by parent is needed for that case.
- Whether a sub-agent record is a restore root is unclear: `restoreSessionTree` requires `rootNode.parentId == nil` (near line 265), and `parentId` comes from directory nesting (`Recording/TranscriptTree.swift`, near lines 185 to 212), which is for forks. A spawn child has `agentSpawn` and no fork parent, so by reading it is a root. This is not tested.

Do (design first; write the design in a task comment and discuss it with the user before the code):
1. A public, read-only listing of the recorded children of a session: for each, the session id, `agentID`, `agentName`, `agentSpawn` (`parentSessionId`, `parentToolCallId`) and the ended marker (Router card `01M6GPT1DM4KZNTT31NMQ0962J`), without restoring anything. Extend `RecordedSessions` / `SessionSummary` if that fits; say in a task comment what already shows.
2. A public, read-only orphan scan of a recorded session: the `RunKey(tool, correlationID)` of each run with a non-terminal journal event and no `.completed`, without restoring and without posting `.lost`. It must give the same set that the restore would mark as lost.
3. Verify and write in a task comment: (a) the real tool name of the `agents` tool as the journal records it; (b) that a spawn child can be a restore root with `restoreSession`; (c) the orphan `correlationID` equals the child `agentSpawn.parentToolCallId` (the completion token) in a real recording.
4. Do not change restore behavior. This card only adds ways to read.

Consumers: FoundationModelsAgents board, card `01M6GNHC0MV9FBT33Z9DTT5TVA` (restore of an interrupted run); FoundationModelsACPAgent board, tag `subagents`, tasks "Cold resume" (`01M6GJPPXWKQJ9E6SK5WD0CWZ7`) and "Re-drive" (`01M6GK6AX0RWQ1PDT89GC0991F`). Related Router cards: ended marker `01M6GPT1DM4KZNTT31NMQ0962J`, claim API `01M6GK8K45DRDT6B4SHB9V60ED`, write-ahead `01M6GK7RHHHC6B6QMJ25FT1QDT`, identity `01M6GQ1F2GK9M1HQV1SNTTQF9Q`, live session accessor `01M6GJJKPTESHZGW7N2AAY83G3`.

## Acceptance Criteria
- [ ] A host can list the recorded children of a session, with `parentToolCallId` and the ended marker, without restoring.
- [ ] A host can read the orphan `RunKey` set of a recorded session without restoring it and without posting `.lost`.
- [ ] The scan gives the same set that the restore marks as lost.
- [ ] A child that wrote no journal event is found by the listing, and not by the scan.
- [ ] A task comment records the three verified facts (tool name, restore root, token equals parent tool call id).
- [ ] No change in restore behavior.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RecordedChildLookupTests.swift`: nested recording with a finished child, an interrupted child and a child with no journal event; listing, ended marker, orphan scan equals the restore set, no side effect.
- [ ] Run `swift test --filter RecordedChildLookupTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents

## Review Findings (2026-11-03 09:48)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified.

- [x] `Sources/FoundationModelsRouter/Directory/RecordedSessions.swift:59` `reuse/reuse` — nestedRecords() is a near-copy of records(). Both walk the recording roots, skip roots that do not exist, keep the first root for each session id, read each index.md with SessionIndexFile.read(in:), and sort newest first. The new function reimplements that loop with its own discovery (TranscriptFileDiscovery) and its own dedup (a Set of ULIDs) instead of extending records(). Two copies of the same root-walk and dedup logic will drift apart when one is fixed. Parameterize the existing folder listing by depth (direct entries for records(), any depth for nestedRecords()), so both share one root walk, one first-root-wins rule and one read-and-sort step. records() then calls the shared helper with the direct-entry mode, and recordedChildren(of:) calls it with the nested mode.
