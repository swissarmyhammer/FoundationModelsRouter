---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m37dpeg2s5g4ws0w9yzqx9xz
  text: |-
    ### research and design choices
    - The two constants were at `GenerationStall.swift:183-189`; the stored interval at `RoutedSessionActor.swift:436-437`. The only test that used the default was `defaultReportIntervalIsThirtySeconds`. No doc or markdown file names the 30 s default.
    - Discovery: `setGenerationStallReportInterval(_:)` was internal on `RoutedSessionActor`. With the default off, no host could turn the report on. Choice: add `setGenerationStallReportInterval(_:)` to the public `RoutedSession` protocol, so the host can install an interval. `RoutedSessionActor` is the one conformer.
    - Discovery: a fork did not inherit the interval. Choice: `performFork` sets the interval of the parent on the child after construction. No new parameter on `makeRoutedSessionActor`.
    - Choice: the stored interval starts at `.zero` (off). `watchGenerationForStalls` already returns at once for a non-positive interval, so no new code path.
    - Tests: the test helper `installGenerationStallReportInterval` is replaced by the public method, and a read accessor `installedGenerationStallReportInterval` is added. New tests: no interval reports nothing after 5 s of silence; `.seconds(1)` reports after 1 s; a fork starts with the interval of its parent. The numbers are local to each test.
  timestamp: 2026-09-23T15:21:08.866984+00:00
- actor: claude-code
  id: 01m37drfbymvvbesxtc19wqpax
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Session/GenerationStall.swift, Session/RoutedSession.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorForking.swift, Tests/FoundationModelsRouterTests/GenerationStallDiagnosticTests.swift, Tests/FoundationModelsRouterTests/Helpers/SessionPlumbingAccess.swift. `swift test`: "Test run with 1318 tests in 149 suites passed ... with 2 known issues" (the 2 known issues are in RealModelHarnessTests and BoundedWaitTests, which exist before this card), "Test run with 1 test in 1 suite passed", "Test run with 19 tests in 3 suites passed". `swift build --build-tests --package-path IntegrationTests`: Build complete. `rg defaultGenerationStallReportInterval` finds nothing.
    - next: commit, then review.
  timestamp: 2026-09-23T15:22:15.294286+00:00
position_column: doing
position_ordinal: '80'
title: Make the stall report default off; a session reports stalls only when the host installs an interval
---
## Decision (from the owner, 2026-09-22)

`RoutedSessionActor.defaultGenerationStallReportInterval` (30 s, `Session/GenerationStall.swift:111-117`) is an invented default and must go. A session reports a `GenerationStall` only when the host installs an interval with `setGenerationStallReportInterval(_:)`. With none installed, the watchdog does not run.

## Why

- No reason for 30 s is recorded.
- The report stops nothing; it is a host UI feature. The host that wants it names the cadence. With the default on, an unconfigured session logged one warning every 30 s for 33 minutes on a turn that was working (django__django-13964, 2026-09-21).

## Sites

- `GenerationStall.swift:111-117`: the two constants. `:119-127` the setter (keep). `:191-193` `watchGenerationForStalls`: `guard interval > .zero` already returns for a non-positive interval.
- `RoutedSessionActor.swift:432-`: the stored `generationStallReportInterval` and its initial value.
- Tests that rely on the 30 s default (`GenerationStallTests`, any test that waits for a report without installing an interval).

## Do this

1. Delete the two constants. The stored interval starts at `.zero`, and the doc says "off until the host installs one".
2. `setGenerationStallReportInterval(_:)` stays as the one way to turn it on. A fork inherits its parent's interval, as it inherits the other session settings; check and add if missing.
3. Update the tests: a session with no interval reports nothing after 5 s of silence; a session with `.seconds(1)` reports after 1 s.
4. ^4799jxg (what counts as progress) is separate and stays.

## Acceptance

- `rg 'defaultGenerationStallReportInterval'` finds nothing.
- The tests above pass. All tests pass. #compaction #limits