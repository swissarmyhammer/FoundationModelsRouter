---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m20vtym7wk3vznf4dm96t41m
  text: |-
    Research done.

    The crash report (`crash-ten-10.ips`) faults at `RoutedSessionActorRecording.swift` line 184, which is `Transcript(entries: entries.prefix(persistedEntryCount))`. The recording sources did not change after 2026-09-02, so the line numbers in the report match the current tree. The frame `initializeWithCopy for ArraySlice` retains the slice owner, which is the array buffer that `backend.transcriptEntries()` returned. The trap in `swift_unknownObjectRetain` shows that buffer reference was already bad. So the cause is an unsynchronized read of a backend array that another thread writes at the same time. No slice is kept across an `await` in `recordTranscriptDelta`.

    The test that drives the failed streaming turn is `RoutedSessionToolContextBindingTests.cancellingAStreamingTurnFlipsTheBoundProbe`. Its `CancellationObservingBackend.streamResponse` starts a producer `Task` that polls the ambient `isCancelled` flag and only then calls `inner.streamResponse`, where `inner` is a `StubSessionBackend`. `StubSessionBackend.streamResponse` appends a `.prompt` and a `.response` entry to its plain `entries` array. At the same time the cancelled turn unwinds on the actor: `runCancellableModelCall` throws, `recordFailedTurn` runs, and `recordTranscriptDelta` reads `inner.transcriptEntries()`. Two threads touch `StubSessionBackend.entries` with no lock. `StubSessionBackend` is `@unchecked Sendable` with the documented invariant that the session drives one backend method at a time; a stream producer that outlives a cut-short turn breaks that invariant. `TurnCancellationTests.HookedSessionBackend` already documents this exact hazard and keeps its transcript behind a `Mutex`.

    Production streams through the pull-based `MLXFoundationModelsSessionBackend.streamResponseFragments` override, so no detached producer writes the live transcript on that path.

    Reproduction: 100 isolated runs of the single test (`swift test --skip-build --filter FoundationModelsRouterTests.RoutedSessionToolContextBindingTests/cancellingAStreamingTurnFlipsTheBoundProbe`) all passed. The race window is the load-then-retain of the array reference, so it needs the thread contention of a full parallel run. Next: run many copies of the test in parallel through the test bundle executable, and loop the full suite.
  timestamp: 2026-09-08T15:57:53.671249+00:00
- actor: claude-code
  id: 01m20wfdrzrzbn55nmq1rcestq
  text: |-
    Reproduced and fixed.

    Reproduction: `scratchpad/stress-parallel.sh` runs the test bundle through `swiftpm-testing-helper` directly (with `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` set to the macOS platform frameworks and usr/lib), 16 processes at the same time, each with `--repetitions 500 --filter RoutedSessionToolContextBindingTests/cancellingAStreamingTurnFlipsTheBoundProbe`. On the unfixed tree, 13 of the 16 processes died with exit 133 (SIGTRAP) inside the first round, some after fewer than 10 repetitions. The fresh crash reports show the same faulting stack as the card: `swift_unknownObjectRetain` under `initializeWithCopy for ArraySlice` under `recordTranscriptDelta` at `RoutedSessionActorRecording.swift` line 184, under `recordFailedTurn`, `streamGenerating`, `wrapAsyncStream`. The single test in isolation passed 100 of 100 runs: the race needs thread contention.

    Cause: `StubSessionBackend` kept `entries` (and its other fields) in plain `var`s with the documented invariant that the session drives one backend method at a time. `CancellationObservingBackend.streamResponse` drives the stub from its own producer task only after it sees the cancellation, so the stub appends the turn's `.prompt` and `.response` entries while the cancelled turn's `recordFailedTurn` reads `transcriptEntries()` on the actor. The reader copied an array buffer the append was freeing.

    Regression test: `Tests/FoundationModelsRouterTests/StubSessionBackendConcurrencyTests.swift`, one test that drives 2000 stream turns from a detached producer while a reader loops on `transcriptEntries()`. Before the fix it dies with signal 6 and the runtime message `Object ... of class _ContiguousArrayStorage deallocated with non-zero retain count 2 ... resulting in a dangling reference`. After the fix it passes in 9 ms.

    Fix: `Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift` now keeps every mutable field in one `Mutex<State>`; each generation call records itself as a whole under that lock (`recordCall(prompt:maxTokens:preflight:)`), and the public property names and the call semantics did not change. The class is now properly `Sendable`, not `@unchecked`. `RoutedSessionToolContextBindingTests` gets a corrected doc on `CancellationObservingBackend` (its old doc claimed the session drives `inner` one call at a time, which the producer task breaks). `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift` gets one doc paragraph on `transcriptEntries()` that states the contract: the turn lock does not end a stream's producer, so a backend whose producer writes the transcript must guard it. No production code changed, no timeout and no retry was added.

    Next: the same parallel stress on the fixed build, then twenty full `swift test` runs.
  timestamp: 2026-09-08T16:09:04.543164+00:00
- actor: claude-code
  id: 01m20wpqmxa95r6jrns98hm3c8
  text: |-
    ### implement — changed
    - evidence: 4 files — Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift (every mutable field behind one `Mutex<State>`, each call recorded as a whole; now properly `Sendable`), Tests/FoundationModelsRouterTests/StubSessionBackendConcurrencyTests.swift (new regression test), Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift (corrected `CancellationObservingBackend` doc), Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift (one doc paragraph on `transcriptEntries()`; no code change). Reproduction before the fix: 16 parallel `swiftpm-testing-helper --repetitions 500 --filter RoutedSessionToolContextBindingTests/cancellingAStreamingTurnFlipsTheBoundProbe` processes, 13 of 16 died with SIGTRAP in round 1, same stack and line 184 as the card. Regression test before the fix: `swift test --filter FoundationModelsRouterTests.StubSessionBackendConcurrencyTests/transcriptReadBesideLiveProducerSeesWholeTurns` exits with signal 6 (`_ContiguousArrayStorage deallocated with non-zero retain count 2`). After the fix: that test `Test run with 1 test in 1 suite passed`; the parallel stress 20 rounds x 16 copies x 500 repetitions all passed; the regression test stress 10 rounds x 8 copies x 200 repetitions all passed; `swift test --skip-build` 20 times: every run `Test run with 1239 tests in 135 suites passed ... with 2 known issues` and `Test run with 83 tests in 10 suites passed`, exit 0, no signal line. No timeout and no retry added.
    - next: /review
  timestamp: 2026-09-08T16:13:04.029675+00:00
- actor: claude-code
  id: 01m20wva0z28k40kfw3wpkk0pe
  text: |-
    ### test — green
    - evidence: `swift build --build-tests` (touched changed files, forced recompile — clean, no warnings in changed files, 1 pre-existing warning `missing creator for mutated node` from mlx-swift_Cmlx.bundle, unrelated to this change); `swift test` — 1239 tests in 135 suites passed + 83 tests in 10 suites passed (1322 total), 0 failed, 0 skipped, 2 known issues (both pre-existing and unrelated: RealModelHarness.swift:72 embedding-slot probe, BoundedWait.swift:114 never-holds-condition probe).
    - The new `StubSessionBackendConcurrencyTests.transcriptReadBesideLiveProducerSeesWholeTurns` (2000 streamed turns racing a `transcriptEntries()` reader) passed with zero torn reads, confirming the `Mutex`-guarded `StubSessionBackend` state fix holds.
    - No new warnings, no skipped tests, no failures found in the changes for this task.
    - next: ready for review.
  timestamp: 2026-09-08T16:15:33.919469+00:00
position_column: doing
position_ordinal: '80'
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

- [x] Find which test drives a `streamResponse` turn that fails, and reproduce the trap with repeated runs of that test or of the full suite.
- [x] Find why the transcript slice `recordTranscriptDelta` reads holds a released object when a streaming turn fails: a transcript the backend mutates while the delta is read, or a slice kept across an `await`.
- [x] Fix the cause, with a regression test that fails before the fix.

### Acceptance Criteria

- [x] The trap is reproduced before the fix, and does not occur after it in twenty full `swift test` runs.
- [x] No timeout and no retry is added to hide the cause.