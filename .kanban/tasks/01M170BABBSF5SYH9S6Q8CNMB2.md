---
assignees:
- claude-code
position_column: todo
position_ordinal: 8f80
title: Two wall-clock test suites fail when the machine is under load
---
## What

Seen while running `swift test` during ^tf6dwx1, with `swiftlint` running at the same
time on the same machine. Two suites failed on that run and on that run only:

- `GenerationStallDiagnosticTests` — "a streaming turn reports the stall against the
  fragments it counted". `GenerationStallDiagnosticTests.swift:292` reported
  `Expectation failed: reported`, after `BoundedWait.swift:114` recorded its
  give-up issue.
- `HumanWaitGateTests` — "a human wait overlapping a turn it is not part of leaves
  the gate at exactly one permit". `HumanWaitGateTests.swift:738` threw
  `RunNeverFinished()`, after the same `BoundedWait.swift:114` give-up.

Both then passed on their own:

    swift test --filter "HumanWaitGateTests|GenerationStallDiagnosticTests"
    Test run with 15 tests in 2 suites passed after 1.985 seconds.

And the whole suite passed on a quiet machine, before and after:

    swift test
    Test run with 1106 tests in 118 suites passed after 5.021 seconds with 2 known issues.

So the two tests are timing-sensitive. `BoundedWait` ends a wait on a wall clock. When
another process takes the cores, the work under measurement does not finish inside that
wall-clock window, and the wait gives up on work that was only slow.

Raising the timeout is not the fix. The fix is to make each of the two tests wait on the
event it is really about, so a slow machine makes the test slower and never red.

## Acceptance Criteria
- [ ] Neither test measures progress against a wall clock alone.
- [ ] Both tests pass with the machine loaded. Run `swift test` while a second heavy
      process runs, and repeat it several times.
- [ ] `BoundedWait` keeps its own contract. Do not weaken it for these two callers.

## Tests
- [ ] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #tests #router-tests