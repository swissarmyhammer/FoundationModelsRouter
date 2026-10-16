---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m52by9nv6kk7shs79q3hptfb
  text: |-
    Research and RED done.
    - respond() runs its send in `wrapAsyncStream`, which starts a plain `Task {}` on the task of the caller. So `mail(_:)` runs with the task-locals of the caller and can read `SessionOwnWork.current` there, next to `ServiceContext.current` (noteCallerContext).
    - The submission closure binds `SessionOwnWork.run(as: context.sessionID)` on the worker task, which inherits no task-local. So the pump cannot bind the carried set around the answer; the set must go into `Self.submission(...)` as a parameter, as `serviceContext` does.
    - Mail joins a running answer through `takeMailJoiningTheAnswer()` -> `deliver(_:)`. A tool body that already runs keeps its task-locals, so the carried set of joined mail reaches only the later submissions of the answer.
    - New test `SessionCloseFromOwnWorkTests/aForkToolThatClosesTheParentWhoseToolWaitsForTheForkGetsTheReturnAtOnce`. RED on the old code with no hang: the fork tool records "fork tool is not the own work of the parent" and does not call close; the test closes the parent itself. One issue only (childProbe.steps).
  timestamp: 2026-10-16T12:45:40.411466+00:00
- actor: claude-code
  id: 01m52cfymyg5cn2t9c8pc2mqm2
  text: |-
    Implementation landed (GREEN).
    - `SessionOwnWork`: new `none`, `isEmpty`, `union(_:)`; `run(as:carrying:_:)` binds current ∪ carried ∪ {session id}.
    - `SessionOutbox`: the map `callerContexts` becomes `callers: [MailID: MailCaller]` (`serviceContext` + `ownWork`). `noteCaller(_:for:)` and `takeCallers(of:)` replace `noteCallerContext`/`takeCallerContext`; `forget(_:)` uses `takeCallers`.
    - `mail(_:)` records `SessionOwnWork.current` of the sender with the tracing context.
    - `RoutedSessionActor.openAnswerCallerWork`: the pump `deliver(_:)` unions the own work of each delivered mail (first batch and each joined continuation), `runAnswer` clears it at the end. The leader keeps the tracing context only.
    - `runCancellableModelCall` passes `openAnswerCallerWork` into `submission(...)` (new parameter `callerWork`), which binds `SessionOwnWork.run(as:carrying:)`.
    - Decision on a batch: union of all sets, not the leader only. Each sender waits for the end of the answer, so a tool of the answer that closes any sender must not wait for it. Limit (documented): mail that joins a running answer reaches only the model calls that start after the join, not a tool body that already runs.
    - Docs: `RoutedSession.close()` now says what is correct (the early return for a tool whose answer delivers mail from this session), instead of the old "do not do this" rule; `SessionOwnWork`, the forking `close()` and the submission doc follow.
    - Cancellation invariants: no change to the pump detach, the cancel marks, or the drain. The early return uses the existing ^3jpewc9 path (`startCloseFromOwnWork`). The close then cancels the tool of the parent; the answer of the child ends after its tool returns; then the parent drain ends. No new wait.
  timestamp: 2026-10-16T12:55:18.942824+00:00
- actor: claude-code
  id: 01m52cg9jpethcbty5sctmqc8b
  text: |-
    ### implement — changed
    - evidence: RED `swift test --filter 'FoundationModelsRouterTests.SessionCloseFromOwnWorkTests/aForkToolThatClosesTheParentWhoseToolWaitsForTheForkGetsTheReturnAtOnce'` 1 test, 1 issue (fork tool not own work of the parent), no hang. GREEN `--filter 'FoundationModelsRouterTests.SessionCloseFromOwnWorkTests'` 4 tests passed. Full `swift test` one run: 1794 tests in 217 suites passed (1 known issue, expected by RealModelHarness), plus 26 and 19 passed. `swift build --package-path IntegrationTests --build-tests` complete. Only warning: the SwiftPM "missing creator for mutated node ... mlx-swift_Cmlx.bundle", which exists before this change. Files: SessionOwnWork.swift, SessionOutbox.swift, RoutedSessionActor.swift, RoutedSessionActorPump.swift, RoutedSessionActorQueueing.swift, RoutedSessionActorAnswerExecution.swift, RoutedSessionActorForking.swift, RoutedSession.swift, Tests SessionCloseFromOwnWorkTests.swift.
    - next: /review
  timestamp: 2026-10-16T12:55:30.134879+00:00
position_column: doing
position_ordinal: '80'
title: close() of a parent from a tool of a child whose answer a parent tool waits for deadlocks
---
Found in ^3jpewc9.

A tool of session P calls child.respond(...) on a child session C (a fork, or another session). A tool of C then calls P.close(). P.close() waits for the end of all work of P, and that work includes the tool of P, which waits for the answer of C, which waits for the tool of C, which waits for P.close(). So the close never returns.

The fix of ^3jpewc9 (SessionOwnWork, a task-local set of session ids bound at the submission of each model call) does not cover this case: the pump of a session is `Task.detached` (wakePump), so the answer of C does not inherit the set of the tool of P. The doc of RoutedSession.close() now tells hosts not to do this.

- [x] Decide: carry the SessionOwnWork set of the sender with the mail into the submission of the answer (respond/send from a tool), or refuse the call, or keep the documented rule only. Decision (orchestrator): carry the set. A batch uses the union of the sets of all its mail, also mail that joins a continuation.
- [x] Fixed-order test for the chosen result, with no hang.
#defect