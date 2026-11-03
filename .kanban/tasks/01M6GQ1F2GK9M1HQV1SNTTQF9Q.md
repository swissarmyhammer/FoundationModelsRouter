---
comments:
- actor: claude-code
  id: 01m6gt6ygnpkh48x83cmm7bddz
  text: |-
    DESIGN (no code written yet). Facts marked CHECK are not read yet; they are the first step of the work.

    Decision: rebuild the identity from the RECORD. The host passes nothing new. Reason: one source of truth, and a host cannot restore with a wrong identity.
    1. `SessionRecord.AgentSpawn` (SessionRecord.swift:43) gets `rootSessionId: ULID`, written at the creation of a sub-agent session from the root id of `parentCall`. This removes the walk of the parent chain, and it works when a parent record is missing. No migration (no backward compatibility): a spawn record without it is invalid.
    2. The restore (SessionTreeRestoration.swift ~409-422, where `agentSpawn` is "not re-applied") re-applies `agentSpawn` and builds an identity value for the session configuration: `parentSessionID`, `rootSessionID`, completion token = `parentToolCallId`. It is only the identity, not the live call. The `ToolContext` of the tools of the restored session gets those ids. CHECK: how `ToolContext` is built from `SessionConfiguration.parentCall`, and whether it can be built from the identity value alone. If not, add a small `ParentCallIdentity` value that `parentCall` also uses.
    3. Tools change on a restore, ids do not: the ids come from the record, so a host argument cannot change them.
    4. Parent not restored or missing: restore the child anyway with the recorded identity. The parent is a live-run fact for the question relay only. A child with no live parent has no `SubagentQuestionTarget`; its questions stay in its own session until a host answers them. This is the same as a root session. No error, because the host may restore the child first (the host decides the order).
    5. List to CHECK, each with a test: hook lineage (key of the root while the root is open), telemetry parent id, directory lineage (`parentCall?.sessionID ?? agentSpawn?.parentSessionId`, RoutedLLM.swift ~194; said to hold already), the question relay target. The comment on the card records which hold already.
    6. Compaction settings, settle grace and `mailOnlyAnswerLimit` come from the recording (as the card says).
    7. A restore of a root is unchanged: no `agentSpawn`.

    Tests (`RestoredSessionIdentityTests`): chain of three sessions, the same rule at every level; restore with other tools; ids equal; missing parent record; root restore unchanged.
  timestamp: 2026-11-03T13:40:07.829795+00:00
- actor: claude-code
  id: 01m6h04tvcwvqwxpd3xt6rafzn
  text: |-
    CHECK answers (read in the code, tests run).
    1. ToolContext from parentCall: ToolContext takes its ids from its MountSite. The parent and root ids come from `ToolContext.childSite`, which calls `MountSite.init(sessionID:runPlane:parentSessionID:rootSessionID:rootRunPlane:sink:...)`. That init is public. A ToolContext cannot be built from an identity value alone (a ToolContext needs a live RunPlane and sink), but a MountSite can: the parent id and root id are plain ULIDs, and rootRunPlane is only used for rootUserPresence. DECISION: no new ParentCallIdentity type. The restore builds the MountSite from the recorded AgentSpawn, and the restored session uses its own run plane as the rootRunPlane (the live root plane is gone after a stop).
    2. Completion token: the ToolContext of the tools of a child does NOT carry the token of the parent call (childSite drops it). The only place that holds it is AgentSpawn.parentToolCallId in the record. The restore now re-applies agentSpawn to the session, so the token is kept there and in the session meta event.
    3. Root id: AgentSpawn gets `rootSessionId` (init default: the parent is the root). RoutedModel.makeSession stamps it from parentCall.rootSessionID. No migration.
    4. Hook lineage: HOLDS already. restoredHooks uses record.agentSpawn.parentSessionId (existing test in HookLineageTests: a restored sub-agent gets the hook key of its restored parent).
    5. Telemetry parent id: HOLDS (no change needed). A fresh spawn child passes parentId nil to its span, and a restored spawn child passes node.parentId, which is nil. Same value before and after.
    6. Directory lineage: HOLDS already (SessionNode.directoryLineage uses agentSpawn.parentSessionId; RouterSessionDirectoryRestoreTests checks .subagent and parent id).
    7. Question relay target: SubagentQuestionTarget.current is read from a live tool call or run body of the PARENT session, by the host that drives the child. The restore does not make it. It is not part of the child identity. A restored child with no live parent has no target, same as a root.
    8. Missing parent: restore with the recorded identity, no error. Tested (parent and middle folders removed, grandchild restores with the same ids).
    9. Layout (host answer): the host writes sub-agent recordings FLAT as top-level folders with agentSpawn.parentSessionId. restoreSession accepts them as roots (the chain-of-three test uses this layout and passes). A session with non-nil parentId (a fork) is rejected by restoreSession as before. A nested spawn child is a layout the host does not write, so no change is made.
  timestamp: 2026-11-03T15:23:49.996007+00:00
- actor: claude-code
  id: 01m6h07hqswmmt0tnmga5ccrww
  text: |-
    ### implement - changed
    - evidence: RestoredSessionIdentityTests (5 tests) failed first (4 failed, the root test passed as it should), then passed. Full `swift test`: 2256 + 38 + 19 tests, 0 failures. Files: RoutedLLM.swift, SessionRecord.swift (AgentSpawn.rootSessionId), SessionTreeRestoration.swift, SessionConfiguration.swift (doc), RestoredSessionIdentityTests.swift, RecordedSessionsPublicSurfaceTests.swift (hand-written record got rootSessionId).
    - next: review. Open: a restored child uses its own run plane as the root run plane, so rootUserPresence is the user presence of the child, not of a live root.
  timestamp: 2026-11-03T15:25:18.969926+00:00
position_column: review
position_ordinal: '8380'
title: 'A restored sub-agent session keeps its identity: parent session id, root session id and parent call'
---
## What
A restored session IS that session, not another (user, 2026-11-03). The tools may change on a restore (the host gives the current tools), but the identity of the session must be the same as before: its own id (already true), its parent session id, its root session id, and the id of the call that started it. Today a restore does not keep the parent and root identity of a sub-agent session.

Facts (from the Agents session review, read in the code, not run):
- `restoreSession` (`Recording/SessionRestoration.swift`, lines 154 to 173) takes `tools`, `instructions`, `userPresence`, `hookSessionKey`, `isNoOpToolCall` and `toolOutputProtection`. It takes no `parentCall`, and `agentSpawn` is "not re-applied" (see `Recording/SessionTreeRestoration.swift`, near lines 409 to 422, where the rest comes from the recording).
- A new sub-agent session is made with `SessionConfiguration.parentCall` (a `ToolContext`) and `agentSpawn` (`AgentSessionMaker.makeSession`, `FoundationModelsAgents`). The tools of that session see `ToolContext.parentSessionID` and `ToolContext.rootSessionID` from it.
- The record already holds `agentSpawn` (`parentSessionId`, `parentToolCallId`) in `SessionRecord`. It holds no root session id; the root is found by following the parent chain.
- The registration in the live directory uses `parentID` from `parentCall?.sessionID ?? agentSpawn?.parentSessionId` (`RoutedLLM.swift`, near line 194), so the directory lineage is already restored (`SessionNode.directoryLineage`).

Do (design first; write the design in a task comment and discuss it with the user before the code):
1. A restored sub-agent session gets the same `parentSessionID`, `rootSessionID` and parent call identity (the completion token of the call that started it, `agentSpawn.parentToolCallId`) in the `ToolContext` of its tools as the original had. Decide if the restore rebuilds this from the record (parent from `agentSpawn`, root by following the chain) or takes a small identity value from the host (parent session id, root session id, completion token). A live `ToolContext` of the original call cannot be rebuilt, so the value is only the identity, not the live call.
2. The restored session must also keep what the identity feeds: the hook lineage (a sub-agent gets the key of the root while the root is open), the telemetry parent id, the directory lineage, and the question relay target (`SubagentQuestionTarget`). Check each, and list in the task comment which already hold and which do not.
3. Keep it separate from configuration: compaction settings, settle grace and `mailOnlyAnswerLimit` may come from the recording in the first version (user decision); the identity may not.
4. A restore of a session whose parent is not restored (the parent is gone) must fail clearly or restore with the recorded identity only; decide and write it down.
5. Do not change FoundationModelsAgents from this card.

Consumer: FoundationModelsAgents board, card `01M6GNHC0MV9FBT33Z9DTT5TVA` (restore of an interrupted run). Related Router cards: ended marker `01M6GPT1DM4KZNTT31NMQ0962J`, write-ahead `01M6GK7RHHHC6B6QMJ25FT1QDT`, claim API `01M6GK8K45DRDT6B4SHB9V60ED`, live session accessor `01M6GJJKPTESHZGW7N2AAY83G3`.

## Acceptance Criteria
- [ ] A restored sub-agent session, in a chain of three sessions (root, child, grandchild), gives its tools at every level the same `parentSessionID` and `rootSessionID` as before the stop.
- [ ] The parent call identity (the completion token) of the restored session equals the recorded `agentSpawn.parentToolCallId`.
- [ ] The hook lineage, the directory lineage and the question relay target of the restored session match the original.
- [ ] Changing the tools on a restore does not change any of these ids.
- [ ] A restore of a root session is unchanged.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/RestoredSessionIdentityTests.swift`: run a nested session with a tool that records its `ToolContext` ids, restore with different tools, compare the ids, a chain of three sessions, missing parent.
- [ ] Run `swift test --filter RestoredSessionIdentityTests`. All pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #subagents