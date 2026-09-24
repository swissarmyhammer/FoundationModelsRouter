---
comments:
- actor: claude-code
  id: 01m3a5qg56y26104c0x3sqdc7q
  text: '2026-09-24: the FoundationModelsACPAgent session confirmed the recommended GenerationStall meanings (step 4). Their `_stalled` rule reads only `visibility == .fragments(0)` and `timeWithoutProgress >= 30 min`, and only when the prompt made no output. With `timeWithoutProgress` counted only while a pass holds its queue place, a request that only waits can never reach their bound. They never use `timeInFlight` for a stop decision, so it can stay the whole model call. They still need the comment with the final shape and names (acceptance criterion) before the change lands.'
  timestamp: 2026-09-24T16:59:38.022678+00:00
depends_on:
- 01M39ZNSNZGBYEY5G8R93KJN94
position_column: todo
position_ordinal: 8b80
title: Do not count a wait for a queue place as a stalled generation, and tell the consumer about the wait
---
## Why

With the per-model generation queue (^8csj2hw, ^93kjn94), a request can wait a long time for a queue place while other sessions generate. The stall watchdog starts at the start of the whole model call (`runCancellableModelCall` → `beginGenerationStallWatch` / `watchGenerationForStalls` in `Session/RoutedSessionActorTurnExecution.swift`). The queue wait is inside that model call. Thus a request that only waits for the GPU reports `generationStalled` with `.fragments(0)`, the same report as a model that cannot generate.

A consumer cannot see the difference. FoundationModelsACPAgent ends a prompt with `_stalled` when a stall report shows zero fragments for 30 minutes and the prompt has made no output (`PromptTurn.endsTurn(_:sawOutput:)`). With some agent sessions on one model, a request that only waits in the queue can be ended as a broken model. Consumer card: FoundationModelsACPAgent ^rfn4m87. Design: `generation-queue.md`, section 2.

## The seam

The queue wait happens in the executor of the per-session queued wrapper (^8csj2hw), not on the session actor. A task-local bound on the session actor does not reach that executor through `LanguageModelSession` (the SDK can run the executor on another task). Thus the per-session wrapper state of ^8csj2hw gets a pass observer that the session actor installs when it makes its backend. The wrapper calls it at three points of each pass: the pass starts to wait for a queue place, the pass takes its place, and the pass ends (in the `defer` that signals the queue). The session actor turns these calls into its own state. This needs one executor for each session, which ^8csj2hw requires.

## Decision: tool-body time is not watched

The stall watch measures generation. It runs only while a pass holds its queue place. It does not run while the request waits for a place, and it does not run while a tool body runs between two passes (the model does not generate then). Now the watch covers the whole model call, tool bodies included, so this is a change of behavior: a tool body that runs longer than the stall interval gives no `generationStalled` report after this task.

The FoundationModelsACPAgent session confirmed on 2026-09-24 that it needs no report during a tool body. Its `_stalled` rule ends a prompt only on `.fragments(0)` AND no output, and a tool call sets `sawOutput`, so a report during a tool body can never end a prompt (their test `aStallPastTheBoundAfterAToolCallDoesNotEndTheTurn`). The only other use is one `notice` log line. The change also removes a known false signal: on 2026-09-08 the Router reported "0 fragments" for a whole healthy run while `runCode` and shell calls completed (their comment on `stalledGenerationBound`).

## What to do

1. Add the pass observer to the per-session wrapper state (see "The seam").
2. Start the stall watch of a pass when the pass takes its queue place, and stop it when the pass ends. Do not count the queue wait or the tool-body time.
3. Tell the consumer that a request waits for a queue place. Choose one:
   (a) a field on `GenerationStall` (for example `waitingForQueue: Bool` or a new `visibility` case), or
   (b) new `SessionEvent` cases, for example `passQueued` and `passStarted`.
   Option (b) also lets a client show "waiting for the model". Remember the `@unknown default` contract of `SessionEvent` for consumers.
4. Decide the meaning of each `GenerationStall` field after this change, and write it in its doc comment. Recommendation:
   - `timeWithoutProgress`: measured only over the time a pass holds its queue place, from the later of the last progress and the moment the current pass took its place.
   - `timeInFlight`: keeps its meaning, the whole model call (queue waits and tool bodies included), so a consumer still sees how long the request has run.
   - `visibility` (`.fragments(n)`): keeps its meaning, the fragments of the whole model call.
   - `lastProgress`: keeps its meaning; a pass that takes its queue place is not progress.
5. Update the doc comments of `generationStalled` in `Session/RoutedSession.swift` and `Session/SessionEvent.swift`, of `GenerationStall`, and of `watchGenerationForStalls`.

## Acceptance Criteria

- [ ] A request that waits for a queue place longer than the stall interval gets no stall report with `.fragments(0)` for that wait (test with two sessions on one pool entry and a held pass).
- [ ] A tool body that runs longer than the stall interval gives no stall report for that time (test with a holding tool, as `PassBoundaryProbeTool` in the test support target).
- [ ] The consumer can see that the request waits for a queue place (test on the chosen event or field).
- [ ] A pass that runs and makes no fragment still gets the stall report as now.
- [ ] A test pins the meaning of `timeWithoutProgress` and `timeInFlight` for a request that waited for a queue place and ran a tool.
- [ ] Before the change lands, a comment on this task gives, for the ACP card ^rfn4m87: (1) the final shape (a `GenerationStall` field or new `SessionEvent` cases) with the exact names, and (2) the meaning of each `GenerationStall` field (`timeWithoutProgress`, `timeInFlight`, `visibility`, `lastProgress`) after this change.
- [ ] The full suite is green. #generation-queue