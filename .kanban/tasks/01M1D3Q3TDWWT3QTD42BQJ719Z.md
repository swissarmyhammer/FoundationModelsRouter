---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: 'A turn-cancellation test fails at random: the cancellation does not reach the tool in time'
---
## What

`swift test` failed one time in three runs on 2026-08-31. The other two runs
passed. Nothing in the working tree touched Swift code. Only `README.md`
changed. The failure is therefore a flake in the test itself.

The failing test:

```
✘ Test "a turn cancelled inside its own proactive fold reports no compaction, because none happened"
  recorded an issue with 1 argument route → the caller's own Task
  at TurnCancellationTests.swift:950:25: Issue recorded
✘ Test run with 1136 tests in 126 suites failed after 7.511 seconds with 3 issues (including 2 known issues).
```

`Tests/FoundationModelsRouterTests/TurnCancellationTests.swift` line 950 holds
this call, inside `awaitCancellationReachingTheTool(_:observer:suspended:)`:

```swift
Issue.record("cancellation never reached the tool call running inside the model call")
```

The helper first calls `BoundedWait.spin(until: { await observer.toolSawCancellation })`.
The spin gave up before the tool observed the cancellation. The bound is too
short for a loaded machine, or the test misses a deterministic signal.

## What to do

- Find why the tool does not see the cancellation inside the bound.
- Make the wait deterministic, or state a bound the machine can always meet.
- Do not raise the bound alone if a real ordering defect causes the miss.

## Acceptance Criteria
- [ ] The cause of the missed cancellation is stated.
- [ ] The test passes 20 times in a row.
- [ ] No other test in the suite becomes slower.

## Tests
- [ ] Run the suite 20 times: `for i in $(seq 20); do swift test --filter TurnCancellationTests || break; done`.

## Note

Found while working task ^2ennye2 (a README correction). #router #defect #flaky-test