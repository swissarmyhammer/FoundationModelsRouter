---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m376zwf7pxj2f8jdff6b5bj7
  text: |-
    ### owner requirement (2026-09-23) — the real-model test for this card

    Add ONE short gated test on Qwen3.8-27B: "a tool call can trigger a compaction". Set the session window artificially small (a test number). Seed the context just under the trigger. Mount one tool whose result crosses the trigger. Run ONE turn: the model calls the tool once, the result crosses the trigger at the tool-result boundary, one compaction runs, and the same turn continues and answers. Assert the compaction event inside the turn, a smaller snapshot, and the answer. At most one model turn per tool call; no long scripted conversation. Owner: "don't make this time consuming or hard, compaction is a simple prompt driven feature". Decide design points yourself and record them here; do not stop to ask.
  timestamp: 2026-09-23T13:23:58.055993+00:00
depends_on:
- 01M34GC0FRM3175J7XJJ6B24GD
- 01M34H27HEABW92JPTM5E8G7PZ
- 01M34TZD45JMX2NK2VYPKE18C2
- 01M35GJ1YW1A6RYJS1235J2ZFG
position_column: todo
position_ordinal: '8280'
title: Compact at a tool-result append inside a turn, with no engine change
---
## Requirement (from the owner)

It must be possible to compact after each append of a turn, and it must be done with no change to `mlx-swift-lm`. The tool loop stays in the FoundationModels session.

## Problem

`runTurnWork` (`Session/RoutedSessionActorTurnExecution.swift:248`) checks `measuredTokens >= budget.triggerTokens` one time, before the first generate call. All growth of a tool-using turn happens after it. Evidence: django__django-13964, 2026-09-21: 41 rounds, 162 tool results, about 225,000 of 262,144 tokens in one turn, no compaction, no patch.

## Facts that shape the design (verified)

1. A compaction cannot take effect during a generate call. The engine holds its own state and cache for that call. The compaction must land between calls.
2. Router wraps every tool (`Hosting/ToolRun.swift`, `Hosting/RunToCompletionRunner.swift`). A tool result passes through Router while the engine loop is in flight. This is the append boundary that Router owns.
3. `ToolFailureDelivery` turns a thrown tool error into text for the model. Only a cancellation goes out as a throw. Thus the wrapper must not throw to stop the call. It must cancel the in-flight model call.
4. `LanguageModelSession` keeps NO entry of a call that throws (`Session/RejectedToolCallRetry.swift:69`). After a cancel, `backend.transcriptEntries()` does not hold the rounds of the stopped call. Router must keep its own copy.
5. Router already gets that copy on the streaming path: each snapshot in `streamResponseFragments` (`Resolution/LiveModelLoader.swift:307`) carries `snapshot.transcriptEntries` and `snapshot.usage` (fed and generated tokens of the newest generate call). `recordLastGenerationCall` keeps only the last entry ID today.
6. `snapshot.transcriptEntries` is Apple's API (`LanguageModelSession.ResponseStream.Snapshot`, FoundationModels.swiftinterface). It is an `ArraySlice<Transcript.Entry>` of the session's own transcript: the entries this response has appended so far. It grows across the rounds of one call and holds `.toolCalls`, `.toolOutput`, `.response` and `.reasoning`. The engine does not build these entries and cannot withhold them. No engine read is needed.
7. `.reasoning` is macOS 27.0 and up. The package targets macOS 27.0, so it is available. Do not assume it on an older platform.
8. The slice's indices are into the session's array. Keep the entries (copy them into an `Array`), not the slice bounds, when you hold them across a stop.
9. The non-streaming `respond` path gets entries only when the call returns. The Router-only compaction works on the streaming path. The ACP agent uses `streamEvents`, which is streaming.
10. `recoverFailedAttempt` already compacts and runs a new attempt in the same turn (`allowOverflowRetry`). This is the re-entry path to use.

## Do this

1. In the backend, keep the newest snapshot's `transcriptEntries` (as an `Array`) and `usage`, not only the last entry ID. Give the actor a read of them.
2. In the tool wrapper, after the result is ready: measure the context as `usage.input` of the newest generate call (exact, from the engine) plus the generated tokens plus the estimate of this tool result. Compare it against `triggerTokens`. Do not use `backend.transcriptEntries()` for this. It does not hold the in-flight rounds.
3. Under the trigger: return the result. No change.
4. Over the trigger: return the result, set a compaction-yield marker on the actor that holds this call's `toolCalls` and `toolOutput` entries, then cancel the in-flight model call. Use a marker that is different from a user stop (`cancelCurrentTurn`), so recovery can tell them apart.
5. In `recoverFailedAttempt`, on the compaction-yield marker: build the full transcript = `backend.transcriptEntries()` + the kept in-flight entries + the yielding round's tool pair. Apply it with `replacingTranscript`, compact it with `performAutoCompaction` to the configured target, emit `.compaction`, then run a new attempt.
6. The new attempt's prompt must be a short continuation ("the context was compacted, your last tool result is above, continue the task"), not `ownPrompt` again. The compacted transcript already holds the original prompt. The overflow retry re-sends `ownPrompt`, which is wrong for this case.
7. Limit the yields in one turn, as `RejectedToolCallRetry.limit` does.
8. Compact at a high-water mark. A compaction makes the prompt cache invalid. The next call pays a full prefill of the compacted transcript.

## Recording

The compaction goes through `performAutoCompaction`, so it gets the same checkpoint and the same append-only history as a turn-start compaction. The rebuilt in-flight entries are new to the recorder at that point. The id-diff in `RoutedSessionActorCompaction.swift:375` must record them before the boundary entry, so they are on disk before the compaction removes them from the live window.

## Acceptance

- A test with a scripted streaming backend and a tool with a large result: the context crosses the trigger at a tool result, one compaction runs, the same turn continues with one more attempt and ends with a response. The caller sees one turn and one stop reason.
- The rebuilt transcript before the compaction holds the in-flight entries (with `.reasoning`) and the yielding tool pair, in order.
- The recorded transcript shows the in-flight rounds, then the compaction boundary, then the continuation attempt, in that order.
- A user stop during the same turn is still a user stop, not a compaction.

## Verification after merge

The peer session (foundationmodelsacpagent-08) will run SWE-bench django__django-13964: one prompt, 41 rounds, which ended `_truncated` with no patch. Tell that session the commit when the chain is on main.

Requested by foundationmodelsacpagent-08. #compaction