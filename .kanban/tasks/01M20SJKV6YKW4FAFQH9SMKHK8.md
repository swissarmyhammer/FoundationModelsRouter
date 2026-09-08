---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: A failed streaming turn traps in recordTranscriptDelta while it records the failed turn
---
### What

Found while implementing task ^7a0qs4p. In one full `swift test` run of twenty, the test process died with `EXC_BREAKPOINT` (SIGTRAP, signal 5) about 0.45 s after the run started, before any test recorded an issue. No test failed. The `FoundationModelsRouterTests` target reported `exited with unexpected signal code 5`, and the run wrote no summary line for that target.

The crash report is `~/Library/Logs/DiagnosticReports/swiftpm-testing-helper-2026-09-08-101427.ips`. A copy is in the session scratchpad as `crash-ten-10.ips`. The faulting thread is thread 10 on the cooperative pool:

```
libswiftCore.dylib  swift_unknownObjectRetain +44
libswiftCore.dylib  initializeWithCopy for ArraySlice +48
FoundationModels    +1054636 (no symbol)
RoutedSessionActor.recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)
RoutedSessionActor.finishTurn(grammar:since:usageBefore:pendingEvents:onEvent:)
RoutedSessionActor.finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:onEvent:)
RoutedSessionActor.recordFailedTurn(grammar:since:usageBefore:pendingEvents:onEvent:)
RoutedSessionActor.runTurnAttempt(grammar:pendingEvents:ownPrompt:onEvent:allowOverflowRetry:_:)
RoutedSessionActor.runTurnWork(grammar:turnId:promptId:pendingEvents:ownPrompt:onEvent:_:)
RoutedSessionActor.runTurn(...)  inside Tracer.withSpan
RoutedSessionActor.generate(grammar:entryPoint:prompt:onEvent:_:)
RoutedSessionActor.streamGenerating(prompt:maxTokens:into:)
RoutedSessionActor.streamResponse(to:maxTokens:)
```

So a streaming turn failed, `recordFailedTurn` ran (the bracket the RoutedSession cancellation invariants require), and `recordTranscriptDelta` copied a slice of the backend transcript inside Apple's `FoundationModels` framework. The retain trapped: the slice held an object that was released or invalid at that moment. The report does not name the test. Other threads at that moment were in `MultiTurnSessionTests.forkHoldsTurnLockDuringMakeFork()` (a `respond` turn on a different thread), `SessionTreeRestorationTests`, `TranscriptEntryMapperTests` and `TranscriptReconstructionTests`.

The nineteen other full runs of the same binary passed all 1238 tests. The change under ^7a0qs4p touches one test that runs no streaming turn, so this crash is independent of that change.

### What to do

- [ ] Find which test drives a `streamResponse` turn that fails, and reproduce the trap with repeated runs of that test or of the full suite.
- [ ] Find why the transcript slice `recordTranscriptDelta` reads holds a released object when a streaming turn fails: a transcript the backend mutates while the delta is read, or a slice kept across an `await`.
- [ ] Fix the cause, with a regression test that fails before the fix.

### Acceptance Criteria

- [ ] The trap is reproduced before the fix, and does not occur after it in twenty full `swift test` runs.
- [ ] No timeout and no retry is added to hide the cause.