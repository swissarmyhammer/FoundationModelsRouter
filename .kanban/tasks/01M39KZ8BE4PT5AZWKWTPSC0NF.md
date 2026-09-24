---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m39mn00y58myatxekhjh9t18
  text: |-
    Research (implement step):
    - The render to the model is the live backend transcript. `runCompaction` (RoutedSessionActorCompaction.swift) replaces the backend with `Summarization.snapshot`: instructions + boundary (summary) entry + protected entries. The next compaction summarizes that live context, so snapshot 2 replaces snapshot 1 in the render. Decision 2 holds in the code already; the new tests prove it.
    - The recorded transcript: `runCompaction` records only the new entries by id (`TranscriptDiffer.diffByEntryId`). It never removes a recorded event. Decision 3 holds in the code already; a new test proves it.
    - The defect is only the counter. `finishTurn` sets `usageState` to the usage delta of the whole attempt (the sum of all generation calls). The fix: the ledger keeps the usage of the newest ended call (fed + generated = the render of that call plus its output), and `finishTurn` sets `usageState` from it. `contextFill`, `compactsAfterCeilingStop`, the pre-turn trigger check, `turnEnded.contextFill` and so `SessionProjection.contextFill` all read `usageState`.
    - `turnEnded.tokensIn/tokensOut` and the `.response` stamp stay the sum of the calls: they are the cost of the attempt, not the context.
    - The existing test `GenerationCallUsageTests.turnStampStaysTheSum` expects `turnEnded.contextFill` = the sum (750/1000). It contradicts decision 1; it changes to 370/1000.
    - Found and not in the scope of this card: a restored session reads its counter from the newest stamped `.response` event (`TranscriptTree.restoredUsageState`), which is the sum. The tree loads only entry events, so the `.generationCall` events are not there. A new task records it.
  timestamp: 2026-09-24T12:01:10.174149+00:00
- actor: claude-code
  id: 01m39n3c1p0871r8hwg48g359g
  text: |-
    Implementation (TDD):
    - RED: the new suite `CompactionRenderCounterTests` (6 tests) and the changed `GenerationCallUsageTests.turnStampStaysTheSum` ran before the fix. The 3 counter tests and the changed test failed on the sum (for example 750 in place of 370). The ceiling-stop test failed because the session tried a compaction on the sum. The 3 render/transcript tests passed at once: decisions 2 and 3 already hold in the code (see the research comment). They stay as the acceptance proof.
    - GREEN: `GenerationCallLedger.newestCall` keeps the usage of the newest ended call (`takeGenerationCall`). `finishTurn` sets `usageState` from it, not from the delta of the attempt. The comment in `finishTurn` now states the render rule. The compaction restart in `runCompaction` did not change; its rescale now calibrates against the render size, not against the sum.
    - `turnEnded.tokensIn/tokensOut` and the `.response` stamp stay the sum of the calls (the cost). `turnEnded.contextFill` reads the counter.
    - Side effect to know: the turn span attributes `tokens.in` / `tokens.out` read `usageState`, so they now carry the newest call, not the sum of the attempt. The doc table on `RoutedSession.respond(to:maxTokens:)` states this now.
    - Test helper trap: a scripted executor that gives the same entry id to the response of two turns makes the SDK throw "Session ended without producing a response". `RenderProbeLanguageModel` makes a new UUID entry id at each call.
    - Not in scope, recorded as ^tcep2pc: a restored session reads its counter from the `.response` stamp, which is the sum.
  timestamp: 2026-09-24T12:09:01.238144+00:00
- actor: claude-code
  id: 01m39n3f2z0tckd4nd4tnw8twt
  text: |-
    ### implement — changed
    - evidence: 10 files. Sources: Session/RoutedSessionActorGenerationCalls.swift, Session/RoutedSessionActorRecording.swift, Session/RoutedSessionActor.swift, Session/RoutedSession.swift, Session/RoutedSessionActorTurnExecution.swift, Compaction/TokenBudget.swift. Tests: CompactionRenderCounterTests.swift (new, 6 tests), Helpers/RenderProbeLanguageModel.swift (new), Helpers/MeteredToolLoopLanguageModel.swift (budget parameter), GenerationCallUsageTests.swift (turnStampStaysTheSum expects 370, not 750). `swift build --build-tests`: 0 errors, 0 warnings. `swift test`: 1339 tests in 151 suites passed (2 known issues that existed before, in RealModelHarness and BoundedWait).
    - next: /review. New task ^tcep2pc for the restore path.
  timestamp: 2026-09-24T12:09:04.351253+00:00
- actor: claude-code
  id: 01m39n903fsv123wvptfxz5a7w
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` clean (no compile warnings). `swift test` — 1339+1+19 = 1359 tests, 0 failed, 0 skipped, 2 known issues (pre-existing, in BoundedWaitTests.swift, not part of this task's files, and intended as a test assertion, not a defect).
    - the two suites for this task both pass: "Generation call usage: one record for each generation call of a turn" and "The render to the model and its token counter restart at each compaction" (Tests/FoundationModelsRouterTests/CompactionRenderCounterTests.swift).
    - one build-system note is present, not a compiler warning: `warning: missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)`. This comes from the mlx-swift-lm dependency's bundle target, not from FoundationModelsRouter code, and is not new from this task's files.
    - next: none. The build is clean.
  timestamp: 2026-09-24T12:12:05.615579+00:00
position_column: doing
position_ordinal: '80'
title: The context sent to the model and its token counter must restart at each compaction
---
## Decisions (user, 2026-09-24)

1. The token count must know about compaction. A compaction restarts the counter. The counter goes up, restarts at a compaction, goes up again, and repeats. A count across the whole history (across compactions) is wrong.
2. The rendered output that the session sends to the model for generation must know about compaction. It contains only these parts, in this order:
   1. the instructions (always, at each call);
   2. the latest compaction (its snapshot);
   3. the messages since the latest compaction.
   A message from before the latest compaction goes to the model only through the snapshot.
3. The recorded transcript keeps full fidelity. A compaction changes only the render to the model and the counter. The transcript keeps each entry from before and after each compaction, and each compaction snapshot. No compaction removes or replaces a recorded entry.

The counter of decision 1 counts the rendered output of decision 2. Thus one compaction restarts both at the same time. The full transcript of decision 3 is not the render, and the counter does not count it.

## Summary

- The real context of each generation call was never more than 59,672 tokens (0.228 of the window). The compaction at a tool-result append (^9ddjkjm, 1c5593a) was correct when it did not start. It measures the context of the newest call (`noteToolResult`, `contextOfNewestCall`).
- The logged value 1.877 is not a context. It is the SUM of the fed and generated tokens of ALL generation calls of one attempt, divided by the window. The counter does not restart at a compaction.
- `compactsAfterCeilingStop` reads the same sum. Thus a ceiling stop at a real fill of 0.228 caused a compaction.

## The run

- Agent: FoundationModelsACPAgent on Router bbad3ce (contains 1c5593a for ^9ddjkjm and the ^46bz58k follow-up).
- Instance: SWE-bench django__django-13964, one ACP prompt, one turn.
- Model: mlx-community/Qwen3.8-27B-mxfp4.
- Time: 2026-09-23, 18:50 to 19:35. Result: `_truncated`, empty patch, 2,741 s agent time.
- Evidence files (in FoundationModelsACPAgent):
  - `bench/preds.t90.transcripts/django__django-13964/01M38ATWY3RB45SQSYD5BX53P8/transcript.jsonl`
  - `bench/run.t90.log`, `bench/preds.t90.runs.jsonl`
  - `log show --start "2026-09-23 18:50:00" --end "2026-09-23 19:36:00" --predicate 'process == "acp-agent"'`

## Evidence

Agent log:

```
18:50:23.426 [FoundationModelsACPAgent:Session] session budget: context=262144 trigger=0.800000 target=0.500000
19:16:25.088 [FoundationModelsRouter:CompactionYield] session 01M38ATWY3RB45SQSYD5BX53P8: an attempt stopped at its output token ceiling with the context at or over the trigger; the turn compacts and goes on
19:34:56.155 [FoundationModelsACPAgent:PromptTurn] session 01M38ATWY3RB45SQSYD5BX53P8: model mlx-community/Qwen3.8-27B-mxfp4 ended with _truncated: tokensIn=694878 tokensOut=72856 contextFill=1.877
```

The trigger is 0.8 × 262,144 = 209,715 tokens.

Generation call records in the transcript (31 calls). Each record gives the real context of one call:

| seq | fed | generated | context | note |
|---|---|---|---|---|
| 1 | 4,064 | 144 | 4,208 | first call |
| 132 | 20,055 | 39,617 | 59,672 | ceiling stop; largest real context (0.228) |
| 173 | 43,141 | 56 | 43,197 | last call before the recorded compaction prompt |
| 225 | 43,912 | 12,182 | 56,094 | ceiling stop; turn ends `_truncated` |

Sums of the generation call records, per attempt:

| attempt | sum fed | sum generated | sum / 262,144 | `.response` record |
|---|---|---|---|---|
| seq 1 to 132 | 232,201 | 43,418 | 1.051 | seq 130: tokensIn 232,201, tokensOut 43,418 |
| seq 133 to 225 | 462,677 | 29,438 | 1.877 | seq 223: tokensIn 462,677, tokensOut 29,438 |

The two sums are equal to the `.response` records and to the logged `contextFill=1.877`.

## Cause (read in the code)

- `RoutedSessionActorRecording.swift:37`: `usage` is `usageDelta(before:after:)` of the whole attempt.
- `RoutedSessionActorRecording.swift:63`: `usageState = .measured(input: usage.input, output: usage.output)`.
- The comment at `RoutedSessionActorRecording.swift:55-61` says: "generation is stateless, so that turn's own delta *is* the whole transcript's size". This is correct only for an attempt with one generation call. A tool loop feeds the full transcript at each call, so the delta adds each full context again.
- `contextFill` (`RoutedSessionActorCompaction.swift:64`) and `compactsAfterCeilingStop` (`RoutedSessionActorCompactionYield.swift:200-206`) both read `usageState.measuredTokens`.
- The render path to the model is not examined yet. The implementer must find where the session renders the transcript for a generation call, and make sure that it follows decision 2 and does not remove entries from the recorded transcript (decision 3).

## Expected

- Each generation call receives: the instructions, then the latest compaction snapshot, then the messages since the latest compaction. When there is no compaction yet, it receives the instructions and all messages.
- The recorded transcript keeps all entries and all snapshots, at full fidelity. The render is a view of the transcript, not a replacement of it.
- The session keeps one context token counter. It counts the rendered output, not the full transcript.
- A compaction restarts the counter from the instructions plus the new snapshot.
- After the restart, the counter goes up with the messages that the session adds. It does not add the full context again for each generation call of a tool loop.
- The next compaction restarts the render and the counter again.
- `contextFill`, `compactsAfterCeilingStop`, `turnEnded` usage and `SessionProjection.contextFill` all read this counter.

## Acceptance

- A test: after a compaction, the rendered output of the next generation call is the instructions + latest snapshot + messages since that snapshot. It contains the instructions, and it contains no message from before the snapshot.
- A test: after two compactions, only the second snapshot is in the render. The first snapshot is not. The instructions are in the render.
- A test: after two compactions, the recorded transcript still contains each entry from before each compaction and both snapshots, unchanged.
- A test: a tool loop of two or more generation calls. The counter is the size of the rendered output, not the sum of the calls.
- A test: the counter goes up, a compaction occurs, the counter restarts from the instructions + snapshot, then goes up again. The count includes the instructions and no message from before the compaction.
- A test: a ceiling stop with a counter under the trigger does not compact, although the sum of the calls is over the trigger.
- The comment at `RoutedSessionActorRecording.swift:55-61` agrees with the new behavior.

## Related

- ^gfxd7av: one generate call can generate tens of thousands of tokens before it stops at the ceiling.

## Source

A peer session (foundationmodelsacpagent-e5) reported the run. The analysis comes from the evidence files and the Router code at bbad3ce.