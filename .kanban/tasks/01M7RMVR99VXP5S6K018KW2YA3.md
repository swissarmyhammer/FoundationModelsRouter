---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
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

- [ ] No `Task.sleep` in `Tests/FoundationModelsRouterTests` that a test result depends on.
- [ ] The changed suites pass with a `Target.Suite` filter, and the full `swift test` passes one time.