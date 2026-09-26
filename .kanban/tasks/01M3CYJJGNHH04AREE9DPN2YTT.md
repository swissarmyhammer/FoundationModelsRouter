---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3dgq923wmez2bpgssdevtg2
  text: |-
    Research (picked up, in doing).

    Facts:
    - `RoutedSessionActor.transcript` waits on `turnLock`, except when `isInsideOwnTurnToolCall`. `performFork` throws `forkDuringSameSessionTurn` from an own tool call, then waits on `turnLock` and calls `backend.makeFork(tools:)`, which reads the LIVE backend transcript.
    - Each submission is recorded by `finishTurn(...)` (success and failure paths, compaction yield and repetition stop included), which runs `recordTranscriptDelta`. That is the "end of submission" settled point.
    - `noteToolResult(_:)` is the tool-result boundary. It runs inside the tool task, under the open `ModelCallMark` of the call. It already reads `backend.transcriptEntries()`. At that time the SDK is suspended in the tool call; the output of the call is not in the transcript yet.
    - A compaction (`applyCompaction`) and a repetition render reset `persistedBaseline` and replace the backend. A read after `compact()` must show the compacted transcript, so these are settled points too.
    - `InFlightTranscript.removingUnansweredCalls` is private and scoped to the entries of one attempt. With an empty "before attempt" set it applies to the last `.toolCalls` entry of a whole transcript.
    - `LanguageModelSessionBackend` has no way to make a fork with the child tools from a GIVEN transcript: `makeFork(tools:)` reads its own history, `replacingTranscript(_:)` keeps its own tools.

    Decisions (and why):
    1. A new value type `SettledTranscript` (entries, `recordedEntryCount`, `historyOrdinal`). The fork needs the recording cut of the same moment: at a tool-result boundary the entries of the running submission are not recorded yet. The child therefore takes `persistedEntryCount = recordedEntryCount` (clamped to its seed), so the child records those entries itself and a restore of the child does not lose them.
    2. New protocol requirement `LanguageModelSessionBackend.makeFork(tools:seededFrom:)`. The default forwards to `makeFork(tools:)` (the old behavior), so the test backends that wrap a stub keep working; the doc says that such a backend reads its own history. `MLXFoundationModelsSessionBackend` and `StubSessionBackend` implement it and seed from the given transcript.
    3. `fork(workingDirectory:)` keeps `async throws` in the protocol, so no consumer gets a new warning; it throws nothing now.
    4. The tool-result boundary settles only when the mark of the call is open for this session (the same fact `isInsideOwnTurnToolCall` read), so a tool body that outlived its call never copies a live transcript.
  timestamp: 2026-09-26T00:09:28.387722+00:00
- actor: claude-code
  id: 01m3dhpnbse76pmftyycx6qvgt
  text: |-
    Implementation landed (not committed).

    What changed:
    - New `Sources/FoundationModelsRouter/Session/SettledTranscript.swift`: the value (entries, `recordedEntryCount`, `historyOrdinal`) and `removingUnansweredCalls()` for a fork seed. The recorded count stops before the first entry that the removal changed.
    - `RoutedSessionActor.settledTranscript` + `settleTranscript()`. Settled points: `finishTurn` after `recordTranscriptDelta` (every submission, success or failure), `runCompaction` after the reseed, `replaceRender` (repetition stop), and `noteToolResult(_:)` through `settleTranscriptAtToolResult()`, which settles only when `ModelCallMark.current` is the OPEN mark of this session. A tool body that outlived its call settles nothing.
    - `transcript` returns the settled copy; no `turnLock`. `performFork` reads `settledTranscript.removingUnansweredCalls()` and calls the new backend requirement `makeFork(tools:seededFrom:)`; no `turnLock`, no refusal. `performFork` no longer throws; `fork` keeps `async throws` in the protocol (no new consumer warnings).
    - `LanguageModelSessionBackend.makeFork(tools:seededFrom:)`: default forwards to `makeFork(tools:)`. `MLXFoundationModelsSessionBackend` implements it (and `makeFork(tools:)` now forwards to it with `liveSession.transcript`). Test stubs `StubSessionBackend` and `HumanWaitGateTests.HookedSessionBackend` implement it.
    - `InFlightTranscript.removingUnansweredCalls` is internal now, with a default empty "before attempt" set (whole transcript). Reused, not copied.
    - Removed `SessionReentryError.forkDuringSameSessionTurn` and `isInsideOwnTurnToolCall`. Docs updated: `RoutedSession.transcript`, `fork`, `SessionReentryError`, `ModelCallMark`, `LanguageModelSessionBackend.transcriptEntries()`, `RouterTracing.forkChildSessionId`.

    Tests restated (meaning changed, not deleted): NestedGenerationReentryTests (tool fork gets a child; tool read gets the settled copy; background fork and read do not wait), MultiTurnSessionTests.forkHoldsTurnLockDuringMakeFork -> forkDoesNotWaitForAnInFlightTurn, HumanWaitGateTests.forkRacingAHumanWait... -> reads the settled transcript, ForkTracingTests refused-span test -> served fork names its child. New: SettledTranscriptTests (3 tests).

    Discovery: in the scripted SDK model, the settled copy at a tool-result boundary holds the `.prompt` and the `.toolCalls` of the round, but not the output (the SDK appends the output after the tool returns). So a fork in round 2 removes the round-1 call. A mutation that skips the removal makes `aToolForksItsOwnSessionDuringTheSubmission` fail.

    Known limit, written here for ^3qx0mpt: a fork taken at a tool-result boundary starts its history at the parent's recorded ordinal; the child records the unrecorded tail itself on its first submission. A child that never generates keeps no copy of that tail on disk.

    Flake seen: in the first full run after a rebuild (load average 19 to 23), the restated HumanWaitGateTests fork test hit the 5 s BoundedWait bound. The fork path has no wait; 8 later full runs and 8 x 100 stress of the suite gave 0 issues. Same family as ^1qpmghh.
  timestamp: 2026-09-26T00:26:36.793915+00:00
- actor: claude-code
  id: 01m3dhpv06nfbd13yf1554wmvh
  text: |-
    ### implement — changed
    - evidence: 21 files (2 new: Sources/.../Session/SettledTranscript.swift, Tests/.../SettledTranscriptTests.swift). `swift test`: 1428 + 4 + 19 = 1451 passed (1448 + 3 new) in 8 of 9 runs, 2 known issues, 0 new warnings; 1 load flake of the new HumanWaitGate fork test in the first run (see comment). Stress 8 x 100: fork/read/re-entry suites 32 tests 0 issues 0 crashes; cancellation/queue suites 89 tests 0 crashes, 1 known ^zr22hpd issue.
    - next: /review
  timestamp: 2026-09-26T00:26:42.566691+00:00
depends_on:
- 01M3CYJ4VS4VF5EEHA01PSQDM9
position_column: doing
position_ordinal: '80'
title: Read and fork a session from its settled transcript, with no wait on turnLock
---
## Why

In the work-queue model no caller waits on a lock (user decision 2026-09-25, "not with a lock"). Now `RoutedSession.transcript` and `fork(workingDirectory:)` wait on `turnLock` while a request runs, and a fork from a tool of the same session throws `SessionReentryError.forkDuringSameSessionTurn`. The user wants the self-call errors to go. Design: `generation-queue.md`, sections 5.6 and 5.8.

The backend transcript changes on the SDK task while a submission runs (see the memory note `stub-backend-producer-race`). So a read must not copy the live backend transcript at a random time. It reads a settled copy that the session actor keeps.

## What to do

1. Add a settled transcript to `RoutedSessionActor`: the entries as of the last settled point. Update it at the end of each submission (success or failure, after the recording diff), and at each tool-result boundary (`noteToolResult(_:)` already reads `backend.transcriptEntries()` there).
2. `transcript` returns the settled transcript at once, from any task. Remove the `turnLock` wait and the `isInsideOwnTurnToolCall` bypass for reads.
3. `fork(workingDirectory:)` seeds the child from the settled transcript, at once. When the settled transcript ends in a round of tool calls with no output, remove those calls (the rule of `InFlightTranscript.removingUnansweredCalls`), so the child starts from a valid transcript. Remove `SessionReentryError.forkDuringSameSessionTurn`.
4. Update the doc comments of `transcript`, `fork(workingDirectory:)` and `SessionReentryError`.

## Acceptance Criteria

- [x] A test: a transcript read from another task while a submission runs returns at once, with the entries of the last settled point. <!-- SettledTranscriptTests.aReadDuringASubmissionReturnsTheSettledEntriesAtOnce; also NestedGenerationReentryTests.aToolBodyReadsItsOwnSessionsTranscript and aBackgroundBodyThatReadsItsOwnSessionsTranscriptDoesNotWaitForTheSubmission (restated) -->
- [x] A test: a tool of a session forks its own session during the submission; the fork succeeds, and the child transcript has no tool call without an output. <!-- SettledTranscriptTests.aToolForksItsOwnSessionDuringTheSubmission (scripted SDK model; a mutation that skips the removal makes it fail); SettledTranscriptTests.theForkSeedDropsUnansweredCallsAndStopsTheRecordedCount; restated: NestedGenerationReentryTests.aToolBodyThatForksItsOwnSessionGetsAChildAtOnce, ForkTracingTests.forkFromItsOwnToolIsServedAndItsSpanNamesTheChild -->
- [x] A test: a background body forks its own session while a submission runs; it does not wait for the submission (replaces `aBackgroundBodyThatForksItsOwnSessionWaitsForTheTurnToEnd`). <!-- NestedGenerationReentryTests.aBackgroundBodyThatForksItsOwnSessionDoesNotWaitForTheSubmission; also MultiTurnSessionTests.forkDoesNotWaitForAnInFlightTurn, HumanWaitGateTests.forkRacingAHumanWaitReadsTheSettledTranscript (restated) -->
- [x] `forkDuringSameSessionTurn` is gone from `Sources`. <!-- rg over Sources, Tests, Examples: 0 matches; isInsideOwnTurnToolCall also gone -->
- [x] A parallel stress run (the `swiftpm-testing-helper` command of the memory note `stub-backend-producer-race`, 8 processes, 100 repetitions) of the new tests shows no crash that HEAD does not also show (^vg6bmq6). <!-- 8 x 100 of the 5 fork/read/re-entry suites (32 tests): 0 issues, 0 crashes. 8 x 100 of 11 cancellation/queue/fork suites (89 tests): 0 crashes, 1 issue = the known ^zr22hpd TurnCancellationTests streamEvents flake -->
- [x] Full `swift test` green, 0 new warnings. <!-- 1428 + 4 + 19 = 1451 tests (1448 + 3 new), passed 8 of 9 runs; the one failure was the new HumanWaitGate fork test hitting the 5 s BoundedWait bound in the first run after a rebuild at load average 19 to 23 (same family as ^1qpmghh); 0 issues in 8 x 100 stress of that suite. Only warning: the known mlx-swift "missing creator" build note -->

#generation-queue