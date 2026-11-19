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
- actor: claude-code
  id: 01m7rqvpapfdd4eg3tcyebn15g
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`: engine 2 findings (2 confirmed, 3 refuted). Orchestrator findings: 2. Total 4: Sources/FoundationModelsRouter/Recording/ForkCutHistory.swift:80 (turn index counts continuation and run-mail prompts; the journal can tell them apart through the `mailDelivered` records of each `.prompt` event), Sources/FoundationModelsRouter/RoutedLLMForking.swift:61 (a recorded fork has no recorded summary after a restart: no lookup by id, no listing, no name check), Tests/FoundationModelsRouterTests/ForkCutHistoryTests.swift:49, Tests/FoundationModelsRouterTests/Helpers/ForkFixtures.swift:274.
    - checks with no finding: the pump change (`answerStartHistoryOrdinal = historyOrdinal` in `runAnswer(of:workId:)`) is one synchronous write and adds no suspension point. The fork reads the live backend transcript only in `settleAtCallingToolCall()`, after a check that the caller is a tool body of the open model call of the source (`SessionCallMark`); the other cuts use `settledTranscript`, and the fork backend comes from `container.makeSession(transcript:)`. The two tests that the implementer did not watch fail can fail: `aRecordedSourceWithNoLauncherIsRefused` and `aSourceThatRecordsNothingCannotFork` each expect one exact error, and another error or no error fails them (`forkError` gives `nil` when the fork throws no error).
    - next: implement the 4 findings; the task stays in review.
  timestamp: 2026-11-19T01:48:39.126735+00:00
- actor: claude-code
  id: 01m7rqwr18p1dnqcgbnt8jpj84
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — ForkCutHistory.swift, RoutedSessionActorForking.swift, RoutedLLMForking.swift (new), RouterSessionDirectory.swift and 12 other source files; 4 new test suites
    - test: green — one full swift test run, 3026 tests in 348 suites, 0 failures
    - commit: 91474651
    - review: findings — ForkCutHistory.swift:80 (turn count), RoutedLLMForking.swift:61 (a recorded fork is not seen after a restart), ForkCutHistoryTests.swift:49, ForkFixtures.swift:274

    Orchestrator decision for finding 1 (the turn unit):
    - A turn index counts each DELIVERED MAIL of sender `.user` (body `.userMessage`) or `.session` (body `.agentMessage`), in the order of the `MailRecord.mailDelivered` segments of the recorded `.prompt` events (and of the running submission). A continuation prompt or a run-mail prompt adds a turn only for such mail that it delivers. This is the same count as ACPAgent: one per user message and one per delivered directory message.
    - One prompt can deliver more than one such mail (a batch). Rounding rule: `.beforeTurn(n)` cuts just before the prompt that delivers mail n. `.afterTurn(n)` cuts at the end of the answer to the prompt that delivers mail n. Thus a cut inside a batch rounds to the batch edge. Write this in the doc and test it.
  timestamp: 2026-11-19T01:49:13.640522+00:00
- actor: claude-code
  id: 01m7rqy60th0mbvw6kzjq4g0h9
  text: 'Correction to the turn unit (agreed with foundationmodelsacpagent-9e): count one turn for each delivered mail whose BODY is `.userMessage` or `.agentMessage`, from any route (a user prompt, the directory, the agents tool, the host mail route), in delivery order. Do not filter on the sender: the agents tool (FoundationModelsAgents AgentRun.swift:794-800) builds the same mail as the directory. A continuation, a background-run result, an elicitation answer and other mail kinds add no turn. The batch rounding stays.'
  timestamp: 2026-11-19T01:50:00.730702+00:00
- actor: claude-code
  id: 01m7rr3rqhehqhg6t7y2fd2aen
  text: |-
    Picked up the 4 review findings (task back in doing). Research:
    - Turn rule (coordinator corrections included): one turn for each delivered mail whose BODY is `.userMessage` or `.agentMessage` (any sender), from the `mailDelivered` records of the `.prompt` events of the source's own journal. A message that the source sends is a tool call in its journal, so it never counts. The running submission's `.prompt` entry comes from the backend with no mail records, so the actor keeps the delivered mail of the running submission (`RunningSubmission.deliveredMail`, one synchronous write in `runOpenedSubmission`) and the fork gives it to the last unrecorded `.prompt` entry, as `attachingDeliveredMailRecords` does when it records.
    - Recorded fork after a restart: `RecordedSessions.summaries()` reads root folders only. Plan: list the root sessions and each recorded fork at any depth (`forkParentId != nil`), with kind `.fork` and `parentID` = `forkParentId`. `restoreSessionTree(root:)` keeps its `notARootSession` contract (RecordedForkTreeRestoreTests); `RoutedModel.restoreSession(id:)` of a fork id restores the tree of the fork root and gives the fork node, so a host launcher (and `fork(_:)` of a recorded fork) works.
  timestamp: 2026-11-19T01:53:03.729726+00:00
- actor: claude-code
  id: 01m7rrje747ag4zkx3pe4pnnqa
  text: |-
    Implementation of the 4 findings landed (not committed). Decisions and discoveries:
    - Turn count: `ForkCutHistory.Entry.prompt(turns:)` holds the number of delivered mails whose body is `.userMessage` or `.agentMessage` (`Mail.startsATurn`, any sender). `turnStarts` lists a prompt once for each such mail (a batch gives the same position more than once). `.beforeTurn(n)` = the prompt that delivers mail n; `.afterTurn(n)` = the next turn prompt after that prompt, or the end of the history, and never after the first prompt of the running answer. `.lastCompletedTurn` = the first prompt of the running answer (any prompt), or the end. The running submission's prompt gets its turns from `RunningSubmission.deliveredMail` (one synchronous write at the top of `runOpenedSubmission`, no new suspension point).
    - Recorded fork: `RecordedSessions.listedEntries()` = the root entries + each nested record with `forkParentId`. `summaries()` and the directory's `recordedSummaries()` read it, so the lookup by id, the listing and the name check see a recorded fork. The kind/parent rule is shared in `SessionRecord.directoryLineage(forkSource:agentSpawn:)` (the restored node uses it too).
    - Restore by id: `RoutedModel.restoreSession(id:)` of a fork id now restores the tree of the root of its chain of sources and gives the fork (the root and the other forks are released, as the forks already were). `restoreSessionTree(root:)` still throws `notARootSession` for a fork id (RecordedForkTreeRestoreTests unchanged).
    - Test helpers: one `DirectoryErrorCapture.error(of:)` (async) in ForkFixtures; `forkError` and ForkCutHistoryTests use it. `ForkFixture.restarted()` makes a new router with the same id over the same folders.
    - Not done as TDD: the new ForkCutHistoryTests failed only at compile time (the API did not exist), so I did not watch them fail on behavior. The 4 restart tests failed on behavior first (no summary, no listing, notARootSession, name `-fork`).

    ### implement — changed
    - evidence: Sources: Directory/RecordedSessions.swift, Directory/RouterSessionDirectory.swift, Recording/ForkCutHistory.swift, Recording/SessionRestoration.swift, Recording/SessionTreeRestoration.swift, Session/RoutedSessionActorAnswerExecution.swift, Session/RoutedSessionActorForking.swift, Session/RoutedSessionActorSubmissionEvents.swift. Tests: ForkCutHistoryTests (29), RouterSessionDirectoryForkTests (+4 restart tests), Helpers/ForkFixtures.swift. Filtered: `FoundationModelsRouterTests.ForkCutHistoryTests` 29 passed; `FoundationModelsRouterTests.RouterSessionDirectoryForkTests/aRecordedFork` 4 passed. Full `swift test` one time: 3041 tests in 348 suites passed, exit 0 (scratchpad/full-test-3.txt); the one `warning:` line is the SwiftPM build note "missing creator for mutated node" of the mlx bundle, no compiler warning.
    - next: review
  timestamp: 2026-11-19T02:01:04.484139+00:00
- actor: claude-code
  id: 01m7rryc654kmb8j4kcjygy1w2
  text: |-
    ### review — findings
    - evidence: `review sha HEAD~1..HEAD`: engine 0 findings (0 confirmed, 1 refuted). Orchestrator findings: 2. Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:245 (a restore of a fork id makes and releases a second instance of the root; its hooks replace and then remove `openSessions[rootID]` of a live root and post `SessionStart`/`SessionEnd(.released)` for it), Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift:427 (no test reads the turns of the running submission through the actor; the write can be removed and no test fails).
    - prior items: the 4 items of 2026-11-18 19:37 are fixed. Turn count: `Mail.startsATurn` (body `.userMessage` or `.agentMessage`, any sender), from the `mailDelivered` records of each recorded `.prompt` and from `RunningSubmission.deliveredMail`; batch rounding and the doc agree with the final rule. Recorded fork: `RecordedSessions.listedEntries()` feeds `summaries()`, `recordedSummaries()` and the name check, with kind `fork` and parent = `forkParentId`; a fork is not renamed by `namingUntitled` (kind check). One `DirectoryErrorCapture.error(of:)` helper.
    - checks with no finding: the write `runningSubmission?.deliveredMail = deliveredMail` in `runOpenedSubmission` is synchronous, comes after `beginSubmission` set `runningSubmission`, and adds no suspension point; the pump invariants stay. The new ForkCutHistoryTests expect exact positions and turn lists, so a wrong count fails them on behavior (for example a run-mail prompt counted as a turn gives `[0, 2]`, not `[0]`). The new `.lastCompletedTurn` behavior is accepted.
    - next: implement the 2 findings; the task stays in review.
  timestamp: 2026-11-19T02:07:35.621542+00:00
- actor: claude-code
  id: 01m7rrz4g4gar6grv6566kcsba
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — RecordedSessions.swift, RouterSessionDirectory.swift, ForkCutHistory.swift, SessionRestoration.swift, SessionTreeRestoration.swift, 3 session actor files; ForkCutHistoryTests, RouterSessionDirectoryForkTests (+4), ForkFixtures
    - test: green — one full swift test run, 3041 tests in 348 suites, 0 failures
    - commit: 4f7b6a4d
    - review: findings — SessionRestoration.swift:245 (a restore of a fork by id makes a second instance of a live root; its hooks replace and then remove the live root's entry), RoutedSessionActorAnswerExecution.swift:427 (no test reaches the deliveredMail write)
  timestamp: 2026-11-19T02:08:00.516416+00:00
- actor: claude-code
  id: 01m7rsse1y69ke78g7jkr8c0gk
  text: |-
    Fixed the 2 findings of 2026-11-18 20:06 (not committed). Decisions and discoveries:
    - Restore by fork id: `restoreSession(id:)` now restores a recorded fork ALONE (`restoreSessionTree(root:..., withForks: false)`). No session of its chain of sources and no fork under it is built, registered or hooked. The history comes from disk (`tree.effectiveTranscript`), which needs no source instance. The hook parent of the fork is the hook session of its source: restored hooks of this restore, else the OPEN hook session in this router (`RouterHooks.openSession(_:)`, new), else the lineage of the source record (`HookLineage.make`, nothing starts). `hookSessionKey` and `instructions` apply to the named session (the fork), as the doc of `restoreSession(id:)` says. With `switchingModel` only the fork moves. `requireClaimable` checks only the named node when `withForks` is false. `treeRoot(ofSession:)` is gone (replaced by `isRecordedFork`). `HookParent.fork(of:)` is the one builder of a fork parent (`SessionHooks.forkParent` uses it).
    - Not changed: a restore of a ROOT id still restores and releases its recorded forks (documented: the forks move with the root under `switchingModel`). With D205 a fork can be live while its source is restored by id, and then the same defect hits the live fork. Recorded as a new task (01M7RSS1HNR7E0G704X1VESQJJ).
    - Running-turn tests: a settled point holds the prompt of a running submission only after a tool result of the open model call (`noteToolResult` settles). So the new suite runs a scripted model with two rounds per turn (`MountFixtures.FastTool`, then `TurnCutForkingTool`, armed by the test), and the second tool forks from inside the running answer, where the SDK waits in the tool call (no clock).
    - Proof: with `runningSubmission?.deliveredMail = deliveredMail` removed for a moment, `aCutBeforeTheRunningTurnIsThePromptOfTheRunningSubmission` failed (caught `.forkCutOutOfRange(.beforeTurn(1))`); reverted. `aCutAfterTheRunningTurnIsOutOfRange` and `aCutBeforeATurnOfARunningRunMailAnswerIsOutOfRange` cannot fail by that removal: `.afterTurn(n)` never depends on the running mail (the end is capped at the first prompt of the running answer, and a turn of the running answer is out of range), and run mail adds no turn. They were shown to fail by other mutations (no `isRunning` check in `endOfCompleteTurn`; every mail counted as a turn), then reverted.
  timestamp: 2026-11-19T02:22:22.270029+00:00
- actor: claude-code
  id: 01m7rssmypx52arbzg30b5hpxg
  text: |-
    ### implement — changed
    - evidence: Sources: Recording/SessionRestoration.swift, Recording/SessionTreeRestoration.swift, Session/SessionHooks.swift; doc links only: Tracing/RouterTelemetry.swift, Session/RoutedSessionActorWorkEvents.swift. Tests: HookLineageTests (+4: a live source keeps its key for a sub-agent, gets no event, ends with one SessionEnd; nothing live starts only the fork), new RouterSessionDirectoryForkRunningTurnTests (3), Helpers/ForkFixtures.swift (`TurnCutForkingTool`). RED: the 4 hook tests failed before the fix (wrong sub-agent key, extra source events, end reasons not `[.completed]`, resumed starts not only the fork). `aCutBeforeTheRunningTurnIsThePromptOfTheRunningSubmission` failed with the `deliveredMail` write removed; the other 2 running-turn tests failed under mutations of `endOfCompleteTurn` and `Entry.prompt(delivering:)`; all reverted. Filtered: 6 suites, 108 tests passed. Full `swift test` one time: 3048 tests in 349 suites passed, exit 0; the one `warning:` line is the SwiftPM mlx bundle note (scratchpad/full-test-4.txt).
    - next: review
  timestamp: 2026-11-19T02:22:29.334257+00:00
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

- [x] Fork at `.lastCompletedTurn` of a source with two turns: the fork has the two turns; a prompt to the fork does not change the source; a prompt to the source does not change the fork.
- [x] Fork at `.lastCompletedTurn` while a turn runs: the running turn is not in the fork, and it ends normally in the source.
- [x] Fork at `.callingToolCall` from inside a tool call: the fork history ends before the call; the source gets the call result.
- [x] Fork at `.historyPosition(n)`: the record has `forkedAtHistoryOrdinal == n`; a position after the end gives `forkCutOutOfRange`.
- [x] Names: `<slug>-fork`, then `<slug>-fork-2`.
- [x] Restart: the fork restores with its prefix and kind `fork`.
- [x] Fork of an archived source: refused. Fork of an unknown source: refused.
- [x] The fork is not in `unendedChildren(of:)` of the source, and it lives on when the source ends or is archived.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e, foundationmodelsmultitool-89 and testudoapp-9a. #d205

## Review Findings (2026-11-18 19:37)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 23 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/ForkCutHistory.swift:80` `orchestrator/d205-turn-rule` — The turn index does not agree with the rule that is agreed with FoundationModelsACPAgent. `recordedEntries(of:)` (:80-90) maps each recorded `.prompt` event that is not a compaction checkpoint to `.prompt`. `Entry.init(_:)` (:61-67) maps each `.prompt` entry of the running submission to `.prompt`. `turnStarts` (:97-99) counts all of them. Thus a tool-loop continuation prompt and a background-run mail prompt start a new turn. The agreed rule: a turn starts only at a prompt that a user message or a delivered directory `session_message` starts. A continuation prompt or a run-mail prompt must not start a turn. The journal can tell the prompt kinds apart, and it needs no new field: each recorded `.prompt` event holds one `MailRecordSegment` with `MailRecord.mailDelivered(Mail)` for each mail that it delivered (`Sources/FoundationModelsRouter/Session/MailRecordSegment.swift:22`), and `Mail` holds `sender` (`.user`, `.session`, `.run`, `.elicitation`, `.catalog`) and `body` (`.userMessage`, `.agentMessage`, `.runEvent`, `.elicitationAnswer`, `.catalogChange`). A user message is `.user`/`.userMessage`, and a directory message is `.session`/`.agentMessage` (`Directory/RouterSessionDirectory.swift:1393`, `:1397`). Classify each `.prompt` from these records, for the recorded entries and for the entries of the running submission. A prompt with no user message and no directory message (a continuation with only run mail or its own prompt, a mail-only answer, an elicitation answer, a catalog change) is not a turn. Also: one prompt can deliver more than one user message (one batch, or a continuation that joins the messages that wait, `takeMailJoiningTheAnswer()`), and ACPAgent counts each user message. Make the Router count equal the ACPAgent count in this case. Change the doc at :13-21 to the agreed rule. Add tests: a continuation prompt is not a turn; a run-mail prompt is not a turn; a directory message is a turn; a prompt with two user messages.
- [x] `Sources/FoundationModelsRouter/RoutedLLMForking.swift:61` `orchestrator/d205-recorded-fork` — A fork records in a folder inside the recording folder of its source. `RecordedSessions.summaries()` (`Sources/FoundationModelsRouter/Directory/RecordedSessions.swift:90`) reads only the root folders, and `RecordedSessions.summary(of:)` (:109) gives only the kind `root` or `subagent`. Thus after a restart a fork has no recorded summary of its own until the source tree is restored: `summary(of:)` (`Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift:802`) does not find it by id; `sessions(matching:)` (:736, through `recordedSummaries()` :849) does not list it; the name check `recordedSummaries(besides:)` (:613) does not count its name, so a new fork of the same source can get the same `<slug>-fork` name. D205 says that a fork is a top-level session that the UI shows as a root session (a tab, Pinned and Recent, Switch to Session). The recorded summaries, the lookup by id and the name check must include a recorded fork, with kind `fork` and the source (`forkParentId`) as `parentID`. Add restart tests: a recorded fork is found by id, it is listed with kind `fork`, and its name blocks the same name for a new fork of the source.
- [x] `Tests/FoundationModelsRouterTests/ForkCutHistoryTests.swift:49` `reuse/reuse` — The private helper directoryError repeats the do/catch that forkError already does in ForkFixtures. Both run a throwing body and return the error cast to SessionDirectoryError or nil. Two copies can drift apart. Move one generic helper into Helpers/ForkFixtures.swift, for example a static func directoryErrorOf<T>(_ body: () throws -> T) -> SessionDirectoryError?. Then ForkCutHistoryTests calls it, and forkError can call it too (or use it for the async case with a matching async helper).
- [x] `Tests/FoundationModelsRouterTests/Helpers/ForkFixtures.swift:274` `reuse/reuse` — forkError(of:at:) repeats the same do/catch error-to-SessionDirectoryError pattern as directoryError in ForkCutHistoryTests. The same mapping is written twice in the test code. Share one error-mapping helper between the two files. Keep the async variant here and have it reuse the shared mapping, instead of keeping a second copy of the catch logic.

## Review Findings (2026-11-18 20:06)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 11 file(s) reviewed, 2 not reviewed. Engine: 0 findings (0 confirmed, 1 refuted). The 2 items below are orchestrator checks.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:245` `orchestrator/d205-restore-fork-by-id` — `restoreSession(id:)` with a fork id restores the full tree of the root (`treeRoot(ofSession:recordingRoot:)`) and then releases the root and the other forks. The root can be live in the same router at this time. Example: the source is live, its recorded fork is not live, and `RouterSessionDirectory.forkSource(of:)` (`Directory/RouterSessionDirectory.swift`) calls `launcher.restoreSession(id: forkID)` for a fork of that fork; a host that opens the recorded fork does the same. The restore then makes a second `SessionHooks` for the id of the live root (`restoredHooks(for:on:)` in `Recording/SessionTreeRestoration.swift`): `start()` calls `RouterHooks.didOpen` and replaces `openSessions[rootID]`, and posts a `SessionStart` (resumed) for the live root. The release of the second root runs `SessionHooks.deinit` → `end(reason: .released)` → `RouterHooks.didClose`, which removes `openSessions[rootID]` of the LIVE root and posts a `SessionEnd(.released)` for it. After this, `subagentParent(of:rootSessionID:)` gives a sub-agent of the live root the id of the root as its key, not the key of the root (for example the shared key of the working directory), and the hook dispatcher gets a second `SessionEnd` when the live root closes. The same occurs for each live fork of the same tree. When nothing is live, the dispatcher gets a `SessionStart` and a `SessionEnd(.released)` for each released node that no caller opened. The restore of a fork id must not register, start or end the hooks of a session that it does not return, and it must not change the hook state of a live session with the same id. Add a test: a live source with a recorded fork; restore the fork by id; the hook dispatcher gets no `SessionEnd` for the source, and a sub-agent of the source still gets the key of the source.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSessionActorAnswerExecution.swift:427` `orchestrator/d205-running-turn-test` — No test reads the turns of the running submission through the actor. `runningSubmission?.deliveredMail = deliveredMail` and the read in `RoutedSessionActorForking.swift` (`ForkCutHistory.runningEntries(_:delivering:)` with `runningSubmission?.deliveredMail ?? []`) can be removed, and no test fails: `ForkCutHistoryTests.theRunningPromptCountsTheTurnsOfItsMail` calls only the static helper, and no directory fork test cuts a source by turn while it runs. Add a directory fork test with a source that runs an answer to a user message after one complete turn: `.beforeTurn(1)` gives the position of the prompt of the running submission (with no write it gives `forkCutOutOfRange`), and `.afterTurn(1)` gives `forkCutOutOfRange`. Add one more with a running answer whose submission delivers only run mail: `.beforeTurn(1)` gives `forkCutOutOfRange`.