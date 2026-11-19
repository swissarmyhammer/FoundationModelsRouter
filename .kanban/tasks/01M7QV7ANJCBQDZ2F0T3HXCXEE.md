---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qw623h9dywdx97a80r0rfk
  text: |-
    Extras D205 is on origin/main at ec528ec (code commit 912d9b0; it also has D204). API:
    - `SessionForkCut`: `.lastCompletedTurn`, `.callingToolCall`, `.historyPosition(Int)`.
    - `SessionForkRequest`: `sourceID`, `cut`, `firstPrompt: String?`, `requestedByClient: String?`, `forker: SessionMessageSender`.
    - `SessionDirectory.fork(_:) async throws -> SessionSummary`, with a default that throws `SessionDirectoryError.forkUnsupported` (the Router compiles before this task).
    - New errors: `archivedSession(ULID)`, `forkCutOutOfRange(SessionForkCut)`, `forkUnsupported`.
    - `SessionName.fork(sourceName:usedNames:)`: `<slug>-fork`, then `-fork-2`, `-fork-3`. Pass the source slug and the names of the sessions in the folder that are not archived.
    - A fork: kind `.fork`, origin `.fork`, `parentID` = source, the same folder and agent, a `started` event; a first prompt starts its first turn.
  timestamp: 2026-11-18T17:44:58.737391+00:00
- actor: claude-code
  id: 01m7qy6e7shme53dt3f6gtep21
  text: |-
    Decision (TestudoApp, for the cut of Fork from Here; the Router rule is mine): the cut is in turn units. Extras adds `SessionForkCut.afterTurn(Int)` and `SessionForkCut.beforeTurn(Int)` (TestudoApp asks Extras). ACPAgent maps an ACP message id to a turn index from its own history.
    Router rule for the mapping:
    - A turn is one `prompt` entry in the recorded history of the source and all entries up to the next `prompt` entry. A `prompt` entry is a user message, or a delivered mail that starts an answer.
    - The index is 0-based: turn 0 is the first `prompt` entry after the instructions.
    - `.beforeTurn(n)`: the history position just before the `prompt` entry of turn n.
    - `.afterTurn(n)`: the history position at the end of turn n (just before the `prompt` entry of turn n+1, or the end of the history when turn n is the last completed turn).
    - A turn index that does not exist, or `.afterTurn(n)` of a turn that still runs, gives `forkCutOutOfRange`.
    - After a compaction, count the turns in the history that the source has now (the same history that a fork copies).
    - Add tests for both cases, for a mail turn, and for an index out of range.
  timestamp: 2026-11-18T18:20:08.313283+00:00
- actor: claude-code
  id: 01m7qy7d9pt9b8kdc4hfsqcjny
  text: |-
    Final turn rule (replaces the compaction line of the earlier comment), agreed with foundationmodelsacpagent-9e:
    - The turn index counts EVERY `prompt` entry ever recorded for the source, also the turns that a compaction folded. This is the same count as the client transcript. 0-based from the first prompt.
    - A cut after the last compaction (`.beforeTurn(n)` or `.afterTurn(n)` with turn n after the compaction summary): the fork gets the compacted context (the summary) plus the turns after it up to the cut.
    - A cut inside the folded range (before or at a turn that the last compaction folded): refused with `forkCutOutOfRange`. Reason: the summary also covers turns after the cut, so a fork from it would know the future. Write this in the doc.
    - An index that does not exist, or `.afterTurn(n)` of a turn that still runs: `forkCutOutOfRange`.
    - Tests: a cut before and after a compaction; a cut in the folded range is refused.
  timestamp: 2026-11-18T18:20:40.118785+00:00
- actor: claude-code
  id: 01m7rnst1rn0aadb4ny9399vek
  text: |-
    Research (implement step). Discoveries and decisions:
    - The directory holds each session weakly. A fork that the directory makes has no other owner, so the directory holds each fork strongly (Registry.heldForks) until the fork leaves the live list (close, archive) or until shutdown(). Decision: no new SessionLauncher requirement.
    - The recording of the source is the one source of the turn positions (every `.prompt` entry ever recorded, the compaction checkpoint is a `.prompt` event too and is not a turn). A source with no durable recording (persistsIndex false) cannot fork: forkUnsupported. Reason: the fork node and its cut live in the recording of the source.
    - Seed of the fork: a cut at or after the settled recorded end comes from the settled transcript (SettledTranscript gets back its historyOrdinal); a cut before it is rendered from the recording, with the same forkPrefix + ContextRenderer path that a restore of the fork uses.
    - Bug found in TranscriptTree.forkPrefix for a cut inside one submission (callingToolCall, historyPosition): the write-ahead markers of the later rounds of that submission come before the last kept entry, their covering entries are after the cut, so a restore of the fork folds them into an open call. Fix: drop a marker that is open in the prefix and that the cut does not count.
    - Running turn: the actor records the history ordinal where the running answer started (pump runAnswer, one synchronous assignment, no new suspension point).
    - `.callingToolCall` needs the open model call mark of the source (SessionCallMark); the live transcript is read only there (tool body, the SDK waits in the call).
    - Recorded source that is not live and not archived: restore it first through the launcher (simpler path), then fork it.
    - Fork facts: agent id and name of the source, origin `.fork`, no tags (the Extras in-memory directory gives none), title from SessionName.fork in the naming lock of register.
    - First prompt: a user message (sender .user).
  timestamp: 2026-11-19T01:12:40.248409+00:00
- actor: claude-code
  id: 01m7rq594qxhys74zfqk5m0ry3
  text: |-
    Implementation landed (not committed). Decisions:
    - Seed backend: `container.makeSession(transcript:tools:samplingMode:)` of the handle of the slot of the source (the restore path), not `makeFork()`: makeFork() reads the live transcript and cannot cut.
    - Restored forks keep their record facts: only `fork(_:)` names a fork (private register variant `namingFork`). The first full run failed RecordedForkTreeRestoreTests.aRestoredForkReadsItsFactsBack when register named every untitled fork; fixed.
    - Recorded forks nest in the source folder, so after a restart they have no recorded summary and restore with the tree of their source (`restoreSessionTree(root:)`). A recorded fork that is not live does not count as a used name.
    - Turn index counts every non-checkpoint `.prompt` entry, also continuation and run-mail prompts; ACPAgent must count the same.
    - A cut inside the folded range (also `.historyPosition` before the end of the newest checkpoint) is out of range.
    - TranscriptTree.forkPrefix now drops a write-ahead marker that is open in the prefix and that the cut does not count (fix for cuts inside one submission).

    ### implement — changed
    - evidence: new Sources: Recording/ForkCutHistory.swift, Session/RoutedSessionActorForking.swift, RoutedLLMForking.swift; changed: Directory/RouterSessionDirectory.swift, Directory/SessionDefaultTitle.swift, Recording/{FoldedHistory,SessionFacts,SessionTreeRestoration,TranscriptReconstruction,TranscriptTree}.swift, RoutedLLM.swift, Session/{RoutedSessionActor,RoutedSessionActorPump,SessionHooks,SettledTranscript}.swift, Tracing/RouterTelemetry.swift. Tests: ForkCutHistoryTests (18), RouterSessionDirectoryForkTests (27), RouterSessionDirectoryForkToolCallTests (4), RouterSessionDirectoryForkCompactionTests (4), HookLineageTests +1, WriteAheadToolCallTests +1, Helpers/ForkFixtures.swift. Full `swift test`: 3026 tests in 348 suites passed, exit 0, no warnings (scratchpad/full-test-2.txt).
    - next: review
  timestamp: 2026-11-19T01:36:24.727109+00:00
position_column: doing
position_ordinal: '80'
title: Fork a live session at a cut point in RouterSessionDirectory (D205)
---
## Goal

`RouterSessionDirectory` implements `fork(_:)`. It makes a live session of kind `fork` from a source session and a cut point. The fork has the agent, the model profile and the tools of the source, and the history of the source up to the cut. The Router records the fork as a fork node of the source, with its cut point, and does not copy the shared history on disk. Decision D205 (`TestudoApp/features/decisions.md`, commit 483664d). Brief: `../.briefs/fork/router-brief.md`; overview `overview.md`.

## Depends on

FoundationModelsExtras (`extras-brief.md`): `SessionDirectory.fork(_:)`, `SessionForkRequest`, `SessionForkCut`, the fork errors (`forkCutOutOfRange` and the refusal of an archived source) and the fork name function of `SessionName`. Do not start before Extras sends the sha. Then update the pin with `swift package --manifest-cache local update FoundationModelsExtras` (first stop a `sourcekit-lsp` whose cwd is this repo). FoundationModelsACPAgent waits for this task.

## Current behavior

- The record has `forkParentId`, `forkedAtEntryCount`, `forkedAtHistoryOrdinal` (`Sources/FoundationModelsRouter/Recording/SessionRecord.swift:105-125`, keys `:265`, decode `:286-288`, encode `:336-338`).
- `RoutedSessionActor` writes the fork fields when it has a `parentId` (`Session/RoutedSessionActor.swift:1013-1015`). The factory is `makeRoutedSessionActor(profile:routerId:id:parentId:...)` (`:175`). Only `RoutedLLM.swift:297` (`parentId: nil`) and the restore (`Recording/SessionTreeRestoration.swift:605`) call it.
- `RoutedSession.fork(workingDirectory:)`, `makeFork(tools:)`, `makeFork(tools:seededFrom:)`, `SessionHooks.makeForkHooks`, `SessionFacts.forFork` and `SettledTranscript.removingUnansweredCalls()` were deleted as unused in commit `0c54184e`. Start from that commit (`git show 0c54184e`).
- The backend can fork: `makeFork()` (`Session/LanguageModelSessionBackend.swift:137`; `Resolution/LiveModelLoader.swift:863`; `Session/HookLayeredLLMContainer.swift:212`).
- Hooks: kind `.fork` (`Session/SessionHooks.swift:17`), origin `.forked` (`:133`).
- A restore reads the prefix of the parent up to the cut (`Recording/TranscriptTree.swift:425`, `forkPrefix(of:entryCount:)` `:469`) and registers a recorded fork as `.fork` with its parent (`Recording/SessionTreeRestoration.swift:838-848`). A recorded fork nests in the recording folder of its parent (`TranscriptTree.swift` `parentId(of:...)`, ~`:252`).
- `register(_:kind:parentID:requestedByClient:)` (`Directory/RouterSessionDirectory.swift:399`) takes the kind `fork`. `start(_:)` (`:1070`) launches a root session and mails its first message. `SessionDefaultTitle.make` (`Directory/SessionDefaultTitle.swift:43-52`).

## Change

1. Implement `fork(_:)`. Refuse an unknown source and an archived source with the Extras errors. A recorded source that is not live: choose the simpler path (restore it first, or fork from its recorded history) and write the choice in the doc.
2. The cut: `.lastCompletedTurn` is the ordinal at the end of the last completed turn (a running turn is not copied and continues in the source). `.callingToolCall` is the ordinal before the open tool call of the source that called the fork (the call gets its result in the source). `.historyPosition(n)` is `n`. A cut after the end gives `forkCutOutOfRange`. The fork has no open tool call at its end (`SettledTranscript.removingUnansweredCalls()`).
3. The session: backend with `makeFork()` seeded with the history up to the cut; the same model profile, slot, instructions and tools (`ForkableTool.forked()` for each tool); `parentId` = source. Record `forkParentId` and `forkedAtHistoryOrdinal`. Register with `kind: .fork` and `parentID` = source. Run the hooks with kind `.fork` and origin `.forked`.
4. The recording: a fork node in the recording of the source, as a restore expects. Do not copy the shared history.
5. The name: the Extras fork name function, among the sessions in the same folder that are not archived (the filter of `SessionDefaultTitle.make`).
6. The first prompt: when `firstPrompt` is not nil, mail it after the fork is registered, as `start(_:)` does.
7. Lifetime: the fork is top level. It does not end with the source, it is not in `unendedChildren(of:)` of the source, and an archive of the source does not archive it.
8. The KV cache reuse is a separate task (^ see the D205 optional task). Do not do it here.

The session actor code has pump and cancellation invariants. Read `routed-session-cancellation-invariants` in the memory folder before a change in `Session/RoutedSessionActor*.swift`.

## Tests

- [ ] Fork at `.lastCompletedTurn` of a source with two turns: the fork has the two turns; a prompt to the fork does not change the source; a prompt to the source does not change the fork.
- [ ] Fork at `.lastCompletedTurn` while a turn runs: the running turn is not in the fork, and it ends normally in the source.
- [ ] Fork at `.callingToolCall` from inside a tool call: the fork history ends before the call; the source gets the call result.
- [ ] Fork at `.historyPosition(n)`: the record has `forkedAtHistoryOrdinal == n`; a position after the end gives `forkCutOutOfRange`.
- [ ] Names: `<slug>-fork`, then `<slug>-fork-2`.
- [ ] Restart: the fork restores with its prefix and kind `fork`.
- [ ] Fork of an archived source: refused. Fork of an unknown source: refused.
- [ ] The fork is not in `unendedChildren(of:)` of the source, and it lives on when the source ends or is archived.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e, foundationmodelsmultitool-89 and testudoapp-9a. #d205