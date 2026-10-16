---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5179qe0hm4eeg9tpz7q27n7
  text: |-
    Research (implement step):
    - All tool calls of a session run inside one site: the submission closure of runCancellableModelCall (RoutedSessionActorAnswerExecution.swift, `submission(of:...)`), which already binds the task-locals of the model call (OriginContext, ModelCallMark, ToolContext ...). The queue worker inherits no task-local, so the binding must be in that closure.
    - A background run body starts in RunPlane.start with `Task {}` (Extras RunPlaneActor), called from inside the tool call (BackgroundToolRunner.start). `Task {}` copies task-locals, so a run body inherits a binding made at the submission.
    - The pump is `Task.detached` (wakePump). So the answer of a child session that a parent tool asks for (child.respond from a parent tool) does NOT run in the task chain of the parent tool. A task-local set cannot carry the parent id into the tools of that child.
    - Decision: a new task-local SET of session ids (SessionOwnWork), bound at the submission site as (inherited set + own id). The set is correct for each task chain that inherits it. It does not fix the case "parent tool waits for a child answer, and a tool of that child closes the parent": the detached pump breaks the inheritance there. That case still deadlocks; recorded as a follow-up task.
    - close() from own work starts the close in `Task.detached` (no task-local, no origin of the tool leaks into the close events, same reason as the detached pump) and stores the handle. A close from outside first waits for that stored close, then runs the idempotent close itself, so two closes do not run at the same time.
    - Test fixtures: BackgroundingBackend (Helpers) calls only BackgroundToolRunner tools and forks to a plain stub. It gets two small changes: it also calls RunToCompletionRunner tools of BackgroundFixtureArguments, and makeFork(tools:) returns a BackgroundingBackend over the child tools. No current suite passes a synchronous BackgroundFixtureArguments tool, and no current suite asks a fork of a BackgroundingBackend session for an answer.
  timestamp: 2026-10-16T02:05:17.632951+00:00
- actor: claude-code
  id: 01m517y5ht0z9g7pc8eh1kf4gq
  text: |-
    ### implement — changed
    - evidence: 7 files — Sources/FoundationModelsRouter/Session/SessionOwnWork.swift (new: @TaskLocal set of session ids, nests by union), RoutedSessionActorAnswerExecution.swift (bound in the submission closure of each model call, by context.sessionID), RoutedSessionActor.swift (closeFromOwnWork handle), RoutedSessionActorForking.swift (close(): own work -> Task.detached close + return; outside -> wait for that close, then the idempotent close; body moved to closeAndAwaitTheEnd()), RoutedSession.swift (doc of close()), Tests/FoundationModelsRouterTests/Helpers/BackgroundingBackendFixtures.swift (also calls RunToCompletionRunner tools; makeFork(tools:) gives a BackgroundingBackend over the child tools), Tests/FoundationModelsRouterTests/SessionCloseFromOwnWorkTests.swift (new).
    - tests: aRunBodyThatClosesItsSessionGetsTheReturnAtOnce (2 cases: direct, Task {} of the tool), aToolCallThatClosesItsSessionGetsTheReturnAtOnce (2 cases), aForkToolThatClosesTheParentWaitsForTheParent. The 4 own-work cases hang without the fix, so they could not be shown red; they pass after the change. The fork test passed before the change too (it guards the old contract for another session).
    - full run: `swift test` one time: "Test run with 1754 tests in 213 suites passed ... with 1 known issue" (the known issue is the existing withKnownIssue in RealModelHarnessTests), plus 26 and 19 tests passed. The only warning is the SwiftPM "missing creator for mutated node" line of the mlx bundle, which is not from source.
    - IntegrationTests: `swift build --build-tests --manifest-cache local` -> Build complete.
    - Decision on the set: kept a SET that nests (union with the inherited set). Note: the pump is Task.detached, so no inheritance crosses from a parent tool into the answer of a child; that case is documented in close() as a thing not to do, and recorded as ^hrkxav5.
    - next: review
  timestamp: 2026-10-16T02:16:27.450172+00:00
position_column: doing
position_ordinal: '80'
title: close() called from a tool body of the same session deadlocks
---
Do not start this task before ^pjycptw is done.

When a tool body of a session calls close() on the same session, close() never returns:
- For a background run, runDrain() waits for runPlane.joinRunBodies() (RoutedSessionActorDrain.swift ~:206), and that waits for the body of the same run, which is the caller of close().
- For a synchronous call inside an answer, runDrain() waits for the pump (Drain ~:210-211), the pump waits for the answer, and the answer waits for the tool.
The doc of close() (RoutedSession.swift ~:624-667) does not forbid this call.

- [x] Fix: option (b), accepted by the reviewer. The session sets a @TaskLocal around each tool call and each run body that it runs. The task-local holds the identity of the session(s) whose work the current task is. close() reads it. If the caller is the own work of this session, close() starts the close in an unstructured Task and returns at once. That close ends after the tool or run body returns. A caller outside the session gets the old contract: when close() returns, the session is closed. The API stays `async` and does not throw. Reason: a refusal with an error (option a) changes the API to throw and gives the tool no way to end its own session; option (b) keeps the API and removes the deadlock.
- [x] Update the doc of close() for the rule.
- [x] Fixed-order test for a background run and for a synchronous tool call: no hang, and the chosen result (the error, or a close that ends after the tool returns). #defect
- [x] Test: a `Task {}` that a tool starts copies the task-local, so close() from it also returns early. The doc of close() says that this is still the own work of the session and is correct.
- [x] Test: a tool of a CHILD or forked session that closes its PARENT session is not the own work of the parent (a different id), so that close waits as normal. The child runs on its own, not inside a parent tool call. The close from the tool of the child returns only after the parent is closed, and does not hang.

Follow-up: ^hrkxav5 (a tool of a child whose answer a parent tool waits for closes the parent: still a deadlock, because the pump is detached and the answer of the child does not inherit the task-local).