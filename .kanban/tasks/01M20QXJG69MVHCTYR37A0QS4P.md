---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: The between-turns report liveness test waits on a wall clock from the main actor
---
### What

`ToolInvocationLivenessTests/reportPostedBetweenTurnsArrivesOnTheSessionStream` has the same shape that made `backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles` time out under load (task ^z5pbt5e): the test is `@MainActor`, its `collecting` Task inherits the main actor, and `BoundedWait.conditionReached` gives that task 5 s of wall clock to move the report from the stream into `SessionEventLog`. Under a starved main actor the bound expires while the report sits in the stream buffer.

It has not failed yet. Task ^z5pbt5e reproduced the shape with `taskpolicy -c background swift test --skip-build` beside 36 `yes > /dev/null` hogs, and that harness is the way to show the failure and the fix.

### What to do

- [ ] Show the test fails under the throttled harness, or record that it does not and why.
- [ ] Remove the wall clock: `outbox.post(report:)` awaits the session actor's `deliverLive`, which yields to the stream before it returns, so after the post the report is already buffered. Close the session and drain the stream with `collect(_:)`, as the sibling test now does.
- [ ] Delete `SessionEventLog` when no test reads it any more.

### Acceptance Criteria

- [ ] The test passes in ten consecutive full `swift test` runs and under the throttled harness.
- [ ] No timeout is raised to hide the cause.