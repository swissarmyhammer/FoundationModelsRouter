---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
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