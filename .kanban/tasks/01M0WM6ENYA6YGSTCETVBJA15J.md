---
position_column: todo
position_ordinal: '80'
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

## Acceptance Criteria

- [ ] The terminal event a `RunKind.process` run settles with reports the
      outcome its own canceler reported, and never `.succeeded`, when a cancel
      stopped it.
- [ ] `wait(completionToken:)` on a stopped process run reports `.stopped`.

## Tests

- [ ] A test parks a `.process` run, cancels it, lets the body settle, and
      asserts the retained terminal event reports `.stopped`.
- [ ] A test asserts `wait(completionToken:)` on that run reports `.stopped`.
- [ ] `swift test` passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

#eventplan #phase-2