---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7rz9ejcv3rqwvrx99syz376
  text: |-
    Research and implementation notes.

    Search of Tests/ and IntegrationTests/Tests for Task.sleep, usleep, Thread.sleep, clock sleep, asyncAfter: only the 5 Task.sleep calls in Helpers/MeteredToolLoopLanguageModel.swift and the 1 in SessionIndexRecordingTests.swift. ManualRunClockWaitTests and SessionDrainTests only use clock.sleep of a manual or held clock as the subject (no real wait).

    Clocks:
    - Generation call times (timeToFirstToken, decodeTime, and callDuration when the first token is seen) come from GenerationPassObserver.clock = RunPlane.clock = Router.runClock. A seam exists: Router.useRunClock(_:). The unseen-first-token callDuration uses ContinuousClock (callStartedAt), but no test that used pacing asserts on that path.
    - SessionRecord.updatedAt comes from Date() in RoutedSessionActor.recordSubmissionStart(). No seam. Decision: no new production seam. The test moves the record back with updateRecord (the prevailing pattern of updateFacts { archivedAt = ... } in other tests), so the second submission must move updatedAt to not before the first value.

    Race found while replacing the metered sleeps: PassOutputRelay reads clock.now for the first output event in the pump, and that read can come after channel.send returns. With a manual clock, a call that advances by its decode right after the send could stamp the first output at prefill+decode. So the paced call waits on GenerationPassObserver.phaseChanges (waitForChange(after:) from the count read before the send) before it advances by the decode. The real sleeps only hid this race.

    Result: the paced times are now exact, so the >= bounds and the leastDecodeTime slack constants in GenerationCallFirstTokenTests and GenerationCallUsageTests became == checks.
  timestamp: 2026-11-19T03:58:29.964475+00:00
- actor: claude-code
  id: 01m7rzafzz8mtvk7yqa55y7cr2
  text: |-
    ### implement — changed
    - evidence: MeteredToolLoopLanguageModel.swift: 5 Task.sleep replaced by MeteredPaceClock (ManualRunClock given to Router.useRunClock; advance by prefill/decode; after the first output send, wait on GenerationPassObserver.phaseChanges.waitForChange(after:) with a "take stacks if this hangs" comment). SessionIndexRecordingTests.swift: Task.sleep(5 ms) replaced by updateRecord that moves updatedAt back 60 s (no Date seam; decided not worth a production seam). GenerationCallFirstTokenTests and GenerationCallUsageTests: >= bounds with leastDecodeTime slack became exact == checks. GenerationCallOutputBufferedTests: comment. Filtered run of 8 suites: 58 tests passed. Full swift test once: 3082 tests in 351 suites passed (plus 50 and 19), exit 0, output in scratchpad/full-suite.txt. No sleeps remain in Tests/ or IntegrationTests/Tests.
    - next: /review
  timestamp: 2026-11-19T03:59:04.191941+00:00
position_column: doing
position_ordinal: '80'
title: Replace the wall-clock sleeps of the metered model and the session index test with a test clock
---
## Problem

While ^szyxq9z removed the last `.timeLimit` traits, a search of `Tests/` found wall-clock sleeps that remain. They are not deadlines, and they do not hang, but the user rule is "no sleeps" in tests:

- `Tests/FoundationModelsRouterTests/Helpers/MeteredToolLoopLanguageModel.swift`: `Task.sleep(for: pacing.prefill)` and `Task.sleep(for: pacing.decode)` pace a call (prefill, first token, decode). Users: `GenerationCallOutputBufferedTests`, `RestoredRenderCounterTests`, `GenerationCallFirstTokenTests`, `GenerationCallUsageTests`, `GenerationCallTracingTests`, `RouterMetricsTests`.
- `Tests/FoundationModelsRouterTests/SessionIndexRecordingTests.swift` (`aLaterSubmissionMovesTheLastActivityAndKeepsTheFirst`): `Task.sleep(for: Self.clockStep)` (5 ms) so that the second `updatedAt` is later than the first.

## Work

- Find out which clock each measured time reads (the metrics of a generation call, the `updatedAt` of the session index).
- Where the production code can take an injected clock, give the test a manual clock and advance it, in place of the sleep.
- Where no seam exists, record why, and decide if a seam is worth the change.
- No time limits, no sleeps, no retries.

## Acceptance

- [x] No `Task.sleep` in `Tests/FoundationModelsRouterTests` that a test result depends on.
- [x] The changed suites pass with a `Target.Suite` filter, and the full `swift test` passes one time.