---
comments:
- actor: claude-code
  id: 01m0yyc40wsdcssz5bsjms99b3
  text: |-
    Picked up. Research: the card predates the engine rework. `DetachingTool` is gone. The shared body is `ToolRun.settle` in Sources/FoundationModelsRouter/Hosting/ToolRun.swift; `terminalFacts(for:)` maps the in-band `Result` to the outcome, so a `.process` run that returns normally after `killpg` gets `.succeeded`. `BackgroundTool.canceler(forCompletionToken:work:run:)` hands a supplied canceler to the mailbox unchanged, so the engine never learns what the canceler reported.

    RED: two new tests in Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift (`aStoppedProcessRunSettlesWithItsCancelersOutcome`, `waitOnAStoppedProcessRunReportsStopped`) fail on the current tree with `terminal.outcome → .succeeded` and `events.last?.outcome → .succeeded`. The defect exists.

    Plan for GREEN: when the run kind is `.process`, `BackgroundTool` routes the supplied canceler through `ToolRun.stop(using:)`. That records the canceler's authoritative outcome in a small `AuthoritativeStopReport` (a pending flag plus a `RaceGate`), and `settle` awaits that report before it builds the terminal, so the natural terminal cannot race ahead of the report. The in-band detail is kept; only the outcome is replaced. A `.swiftTask` run is not changed: cooperative cancellation is a request, so a tool that returns normally after it still reports an honest `.succeeded`.
  timestamp: 2026-08-26T11:48:02.716729+00:00
- actor: claude-code
  id: 01m0yyhpedpwwfvdpprprq14q4
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Hosting/ToolRun.swift (new `AuthoritativeStopReport`, `ToolRun.stop(using:)`, `terminalFacts(for:stoppedAs:)` over `inBandFacts(for:)`), Sources/FoundationModelsRouter/Hosting/BackgroundTool.swift (a `.process` run's supplied canceler is routed through `run.stop(using:)`), Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift (harness gains a `MountFixtures.RecordingSink`; new tests `aStoppedProcessRunSettlesWithItsCancelersOutcome` and `waitOnAStoppedProcessRunReportsStopped`; helpers `settledTerminal(of:through:)` and `stopAndSettle(_:through:opening:)`).
    - TDD: RED proven on the untouched engine (`terminal.outcome → .succeeded`, `events.last?.outcome → .succeeded`), then GREEN.
    - build: `swift build --build-tests` 0 errors, 0 warnings from our code (one `missing creator for mutated node` warning from the mlx-swift bundle dependency only).
    - test: `swift test` — 1058 tests in 104 suites passed, 83 tests in 10 suites passed, 0 failures. The 2 known issues are pre-existing `withKnownIssue` blocks in BoundedWaitTests and RealModelHarnessTests.
    - behavior: a `.swiftTask` run is not changed. Only a `.process` run's terminal outcome takes the canceler's report; the in-band detail is kept. `settle` awaits a pending report, so the natural terminal cannot race ahead of the canceler.
    - next: `/review`.
  timestamp: 2026-08-26T11:51:05.421333+00:00
- actor: claude-code
  id: 01m0yz6d269xb8q9e8jbn8sjw1
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (local) — 2 findings, 2 confirmed, 0 refuted — Sources/FoundationModelsRouter/Hosting/ToolRun.swift:256, Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift:250
    - next: apply the two swift/fluent-usage findings (label the first parameter of `report` and `stopAndSettle`), then run the review again
  timestamp: 2026-08-26T12:02:23.942380+00:00
- actor: claude-code
  id: 01m0yzab5qwggasx1dvq373ehq
  text: |-
    ### implement — changed
    - evidence: 2 files. Sources/FoundationModelsRouter/Hosting/ToolRun.swift: `AuthoritativeStopReport.report(_:)` is now `report(outcome:)`; the one call site in `ToolRun.stop(using:)` and the doc reference on `begin()` are updated. Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift: `stopAndSettle(_:through:opening:)` is now `stopAndSettle(run:through:opening:)`; both call sites (`aStoppedProcessRunSettlesWithItsCancelersOutcome`, `waitOnAStoppedProcessRunReportsStopped`) are updated. A scan of the diff of HEAD~1..HEAD found no other side-effect method with an unlabeled first parameter. Both findings are checked on the card.
    - build: `swift build --build-tests` 0 errors, 0 warnings from our code (one `missing creator for mutated node` warning from the mlx-swift bundle dependency only).
    - test: `swift test --filter DeclaredRunKindTests` 6 tests in 1 suite passed. `swift test` 1058 tests in 104 suites passed with 2 known issues (pre-existing `withKnownIssue` blocks), and 83 tests in 10 suites passed. 0 failures.
    - not committed.
    - next: `/review`.
  timestamp: 2026-08-26T12:04:33.079497+00:00
- actor: claude-code
  id: 01m0yzmwyejt3vqkmmdhw97v0r
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (local backend), 0 findings, 7 validators attempted, 0 failed. The two prior fluent-usage findings (`report(outcome:)` and `stopAndSettle(run:)`) are checked.
    - next: none. The task is in the done column.
  timestamp: 2026-08-26T12:10:18.958995+00:00
- actor: claude-code
  id: 01m0yzna4nj5pbvk4bta60tn33
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — report(outcome:) and stopAndSettle(run:...) labeled; both prior findings checked
    - test: green — swift test, 1058 + 83 tests, 0 failed
    - commit: 7fdb364 (fix follows d2a0d57)
    - review: clean — 0 findings, 7 checks; task moved to done
  timestamp: 2026-08-26T12:10:32.469343+00:00
position_column: done
position_ordinal: fffa80
title: The natural terminal of a killed process run reports .succeeded
---
## What

Found while proving the session-end sweep for FoundationModelsMultitool card
^1hq8xny. This is a **Router** defect, so it is filed here.

`DetachingTool.settle(...)` builds the run's terminal event from
`terminalFacts(for: result)`, where `result` is the `Result<String, Error>` of
the wrapped tool's own call:

```swift
let terminal = OperationEvent(..., kind: .completed, detail: facts.detail, outcome: facts.outcome)
await funnel.settleRun(with: terminal)
return RunSettlement(result: result, terminal: terminal)
```

`SessionMailbox.park(settling:)` takes `Task { await workTask.value.terminal }`,
so THAT event — the engine's — is what `markSettled` retains and what
`wait(completionToken:)` and a sweep hand back.

A `RunKind.process` run is stopped by its own supplied canceler, which sends
`killpg(SIGKILL)` and does NOT cancel `workTask`. The wrapped tool's `call`
therefore returns normally, with a report that reads `status: killed`. So
`terminalFacts` sees `.success` and the retained terminal event reports
`OperationOutcome.succeeded` for a run a `SIGKILL` ended.

The Multitool `Execute` verb posts its OWN terminal event through
`RunEventFunnel`, and that one carries the honest `.stopped` (it reads
`CommandStatus.killed` out of its store). The funnel forwards it upstream and
then drops the engine's, so a SINK sees `.stopped`. Only the value the MAILBOX
retains is wrong.

## Where it shows

- `ToolContext.wait(completionToken:)` on a run that a cancel already stopped
  reports `.succeeded`.
- `SessionMailbox.sweep()` uses the natural terminal when a run settles inside
  the window of its own canceler await. That window is narrow — the canceler
  is two actor hops and the run body needs the reap, the drain and a file read
  — so the sweep almost always synthesizes with the canceler's `.stopped`
  instead. It is a race, not a certainty, and the record it can write is a
  manufactured `.succeeded`.

## Why a capability cannot fix it

`FoundationModelsMultitool` cannot reach it. The outcome comes from the engine's
reading of the wrapped tool's return value, and no declaration a capability
makes changes that reading. A capability that threw instead would report
`.failed`, which is a second wrong word rather than a fix.

## Current tree note

The card predates the engine rework. `DetachingTool` is now `BackgroundTool` /
`RunToCompletionTool` with the shared body in `ToolRun` (`Hosting/ToolRun.swift`),
and `SessionMailbox.park` is `SessionMailbox.track`. The defect was the same.

## Acceptance Criteria

- [x] The terminal event a `RunKind.process` run settles with reports the
      outcome its own canceler reported, and never `.succeeded`, when a cancel
      stopped it.
- [x] `wait(completionToken:)` on a stopped process run reports `.stopped`.

## Tests

- [x] A test tracks a `.process` run, cancels it, lets the body settle, and
      asserts the retained terminal event reports `.stopped`.
- [x] A test asserts `wait(completionToken:)` on that run reports `.stopped`.
- [x] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#eventplan #phase-2

## Review Findings (2026-08-26 06:52)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Sources/FoundationModelsRouter/Hosting/ToolRun.swift:256` `swift/fluent-usage` — The `report` method's parameter is unlabeled, but this is not a value-preserving conversion. Per the fluent-usage rule, the first argument label should only be omitted for value-preserving conversions like type conversions; side-effect methods should have labeled parameters for clarity. Change `func report(_ outcome: OperationOutcome)` to `func report(outcome: OperationOutcome)`.
- [x] `Tests/FoundationModelsRouterTests/DeclaredRunKindTests.swift:250` `swift/fluent-usage` — The first parameter of `stopAndSettle` is unlabeled, but this is not a value-preserving conversion. Per the fluent-usage rule, the first argument label should only be omitted for value-preserving conversions; side-effect methods should have labeled parameters for clarity. Change `_ run: BackgroundRun` to `run: BackgroundRun` on line 250.
