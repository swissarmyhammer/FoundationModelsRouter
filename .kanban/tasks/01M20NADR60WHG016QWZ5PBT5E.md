---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: A background-call liveness test times out under a full parallel test run
---
### What

`ToolInvocationLivenessTests/backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` failed one time in a full `swift test` run of 1238 tests, and passed alone (14 ms) and on the next full run.

The failure: `BoundedWait.conditionReached("the report on streamSessionEvents()")` was never satisfied inside its bound, so `expectOneReportFollowsClose(in:)` found no report. In the failing run, many unrelated tests reported durations near 7.8 seconds, so the machine was under load when the wall-clock bound expired.

Found while implementing ^9hdy3hq. That card did not change this path: it changed only the schema JSON encoder in `TranscriptEntryMapper`.

### What to do

- [ ] Reproduce the timeout under load, for example with a full `swift test` run repeated several times.
- [ ] Find whether the bound is too short under load, or whether the report can be lost when the run settles before the session stream is subscribed.
- [ ] Make the test deterministic: subscribe before the run can settle, or wait on the mailbox settlement instead of a wall clock, as the test's own comment intends.

### Acceptance Criteria

- [ ] The test passes in ten consecutive full `swift test` runs.
- [ ] No timeout is raised to hide the cause.