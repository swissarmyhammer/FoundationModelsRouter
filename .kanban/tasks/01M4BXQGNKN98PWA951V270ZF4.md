---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4c1byje7d9s56k205j57vr9
  text: |-
    Implementation landed (not committed). Discoveries:
    - FoundationModelsExtras main (2c37a78) also holds a91911d, a breaking change: PooledEmbedding has no `dimension` now. The Router does not build with it: LiveModelLoader.swift (LoadedPooledEmbedding.dimension), PooledEmbeddingContainer.swift, RoutedEmbedder.dimension (public) and SlotPoolLoaderTests read it. This is not part of this card. To verify this card, a temporary file Sources/FoundationModelsRouter/TemporaryDimensionShim.swift (extension PooledEmbedding { var dimension: Int { 0 } }) was used, and then removed. A new task records the break.
    - RunPlaneActor.settle removes a run from the open runs and adds it to the settled runs in one step, so readBackgroundRunTokens (open first, then settled) puts each run that was open at the first read in one of the two sets.
    - mailDeliveryMessage prompt text is never sent to the model (runFirstSubmission uses its own prompt when letters is empty), so it stays as is.
    - TDD: RED run showed 4 failures for the right reasons (render line, runMessageDeliveryPrompt suffix x2, runMessage on the feed); the canStartASubmission unit tests passed at once, because that code was done before this pass.
  timestamp: 2026-10-07T20:37:35.950603+00:00
- actor: claude-code
  id: 01m4c1et7bsdk68vsm0ak713qf
  text: |-
    ### implement — changed
    - evidence: 17 files — SessionOutbox.swift, RoutedSessionActorPump.swift, RoutedSessionActorIdle.swift, RoutedSessionActorRunJournal.swift, OperationEventSegment.swift, SessionEvent.swift, SessionAnswer.swift, SessionProjection.swift, SessionTreeRestoration.swift, RoutedSession.md, generation-queue.md, Examples/MultiModelGeneration/main.swift, IntegrationTests RealToolAnswerComparisonTests.swift, Tests SessionOutboxTests.swift, PendingEventInjectionTests.swift, ScriptedToolAnswerComparisonTests.swift, new RunMessageDeliveryTests.swift. With the temporary PooledEmbedding shim (removed after): `swift test --filter "RunMessageDeliveryTests|renderedLineOfARunMessage|SessionOutboxTests"` 45 tests passed; full `swift test` 1529 tests, 9 failed, all embedding-dimension tests that fail only because of the shim (Extras a91911d), 2 known issues. Without the shim the package does not build (Extras a91911d), recorded as ^a6022g2. No CHANGELOG.md in the repo. IntegrationTests package not built.
    - next: ^a6022g2 must land before this card can show a green build; then /review.
  timestamp: 2026-10-07T20:39:09.803859+00:00
- actor: claude-code
  id: 01m4c5t8zzvbd2rs6cb9rq9gvq
  text: |-
    ### review — findings
    - evidence: review sha aad6ae5..5713abe — 2 findings (2 confirmed, 2 refuted) — Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:132, Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:141
    - next: implement — move awaitPrompts and pumpStops into shared test support and use them from all suites that have a copy. The task stays in review.
  timestamp: 2026-10-07T21:55:19.679016+00:00
- actor: claude-code
  id: 01m4c5txd6df6csyhvtr4jkbba
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — earlier in this session (17 files)
    - test: green — swift test, 1531 tests in 192 suites passed (2 known issues)
    - commit: 5713abe (pushed)
    - review: findings — Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:132, Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:141
  timestamp: 2026-10-07T21:55:40.582842+00:00
- actor: claude-code
  id: 01m4c63h65p96zf66g7cfj4ymw
  text: |-
    Review findings fixed (not committed). Discoveries:
    - New shared helper file Tests/FoundationModelsRouterTests/Helpers/SessionPumpWaits.swift: `extension BoundedWait` with `awaitPrompts(_:in:)` (a closure reads the prompts, so each backend type can use it) and `pumpStops(on:)`. It is in the existing Helpers folder of the unit test target, beside BoundedWait.swift. No new target. FoundationModelsRouterTestSupport was not used, because BoundedWait and SignalNeverArrived are in the unit test target.
    - Copies removed: awaitPrompts in RunMessageDeliveryTests, SessionMessagePumpTests, SubmissionAnswerEventTests, and the same bounded wait in RespondRunPlaneDrainTests.prompts(atLeast:reaching:). pumpStops in RunMessageDeliveryTests, SessionMessagePumpTests, MailOnlyAnswerLimitTests, and the inline `conditionReached("the pump ending") { await !session.isPumpRunning }` in RespondRunPlaneDrainTests.
    - Not changed, because they are not the same helper: PerCallMountSessionTests uses AwaitedCondition (no wall-clock bound); RespondRunPlaneDrainTests "the pump ending with no run left" also reads the runs; direct `#expect(await session.isPumpRunning ...)` reads do not wait.
    - Tool note: the `files` edit op with `replace_all: true` replaced only one match in each call. The call-site renames were done with one `perl -pi` substitution and checked with rg and git diff.
  timestamp: 2026-10-07T22:00:22.981708+00:00
- actor: claude-code
  id: 01m4c63zwjmhn74vfjbqk73946
  text: |-
    ### implement — changed
    - evidence: 7 files — new Tests/FoundationModelsRouterTests/Helpers/SessionPumpWaits.swift; RunMessageDeliveryTests.swift, SessionMessagePumpTests.swift, SubmissionAnswerEventTests.swift, MailOnlyAnswerLimitTests.swift, RespondRunPlaneDrainTests.swift. `swift build --build-tests`: Build complete, no warning in a touched file. `swift test --skip-build --filter 'RunMessageDeliveryTests|SessionMessagePumpTests|MailOnlyAnswerLimitTests|SubmissionAnswerEventTests|RespondRunPlaneDrainTests'`: 40 tests in 5 suites passed. Both review findings are checked.
    - next: /review
  timestamp: 2026-10-07T22:00:38.034521+00:00
- actor: claude-code
  id: 01m4c6cg11se0ym6jgh0pc4wvq
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (321339d): 0 findings, 0 confirmed, 1 refuted, 7 attempted, 0 failed. All prior review items are checked.
    - next: none. The task is in done.
  timestamp: 2026-10-07T22:05:16.705280+00:00
- actor: claude-code
  id: 01m4c6cwpg80kbm0gpk9fcj7fp
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 6 test files (shared SessionPumpWaits helper)
    - test: green — swift test, 1531 tests in 192 suites passed, 0 failed (2 known issues)
    - commit: 321339d
    - review: clean — 0 findings, 2 prior items checked; task in done
  timestamp: 2026-10-07T22:05:29.680442+00:00
position_column: done
position_ordinal: ffffffca80
title: Deliver the run message mail kind (OperationEventKind.message)
---
## What

A background run can send a message to its calling session while the run continues. Extras adds `OperationEventKind.message` (never terminal; `detail` holds the text) and `ToolContext.message(_:)`. The Router must deliver this mail. An unheld message starts an answer with no caller message, the same as the terminal of a settled background run. Request from the FoundationModelsAgents session.

## Dependency

Do not start until FoundationModelsExtras `main` has `OperationEventKind.message`. Then stop the sourcekit-lsp of this repo and run `swift package update FoundationModelsExtras --manifest-cache local`.

## Final API names (sent to FoundationModelsAgents)

- `SessionEvent.runMessage(OperationEvent)`: the run journal emits it when it records a `.message` event, at the same point as `.runSettled`. It is on `streamSessionEvents()` always, and on the answer stream when the message arrives in an answer.
- Render (`OperationEventSegment.renderedLine(for:)`): `[<tool>] <op> (<token>) message, still running: <detail>`.

## Changes

1. `SessionOutbox.stage(event:held:)`: stage `.message` as a new pending event. Do not coalesce it.
2. `SessionOutbox.post(event:)`: call `mailObserver?.mailArrived()` for `.completed` and `.message`. Update the doc comments of `SessionMailObserver` and of the actor.
3. `SessionOutbox.canStartASubmission`: replace the `settledRunTokens: Set<String>` parameter with a `BackgroundRunTokens` value (`open: Set<String>`, `settled: Set<String>`). An unheld `.completed` starts a submission when its token is in `settled`. An unheld `.message` starts a submission when its token is in `open` or in `settled`. A message of an in-band run (token not a background run) starts no submission and rides the next submission. Thread the new value through `takeMailStartingASubmission`, `runNextAnswer`, `answerCallerBatch`, `answerMail`, `runAnswer` and `IdleReads`. Read `mailbox.backgroundRuns()` before `mailbox.settledRunTokens()` (the order of `readRunsAndMail()`), so that a run that settles between the two reads is in one of the two sets.
4. `OperationEventSegment.renderedLine(for:)`: add the `.message` case with the render above. Update the doc examples.
5. `RoutedSessionActor.record(event:)`: `deliverLive(.runMessage(event))` for `.message`. Add the case to `SessionEvent` with a doc comment, and to the exhaustive lists in `SessionAnswer.swift` and `SessionProjection.swift`.
6. `SessionTreeRestoration.OrphanRunScan.observe`: treat `.message` as non-terminal, with `.progress` and `.elicitation`.
7. `withdrawStagedEvents(correlationID:)`: no change. When a run settles inside its inline grace, its tool output carries the result, and its staged messages are withdrawn with its other staged events. The journal keeps them.
8. Docs: `RoutedSession.md`, the `generation-queue.md` mail section if it lists the kinds that start a submission, and CHANGELOG.

`mailOnlyAnswerLimit`, `mailDeliveryPaused`, the hold on cancel and the wait while an answer runs apply with no new code, because they act on all mail that can start a submission.

## Tests

- A `.message` post on an open background token, with no caller message, starts an answer. The submission prompt has the message line. The run stays open.
- A later `.completed` on the same token settles the run and starts its own answer.
- A `.message` posted while an answer runs waits. The next answer starts after the first answer ends, and carries it.
- A `.message` of a token that is not a background run starts no answer, and rides the next caller submission.
- `mailOnlyAnswerLimit` holds a `.message` and emits `.mailDeliveryPaused`.
- `.runMessage` is on `streamSessionEvents()`.
- `renderedLine(for:)` of a `.message` event.
- Unit tests of `canStartASubmission` for each kind and token set.

Use a filter that matches real test names (see memory on false passes). #session #mail

## Review Findings (2026-10-07 16:49)

> Scope: `review sha aad6ae5..5713abe` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 8 not reviewed.

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:132` `reuse/reuse` — The new awaitPrompts helper repeats a bounded-wait helper that already exists in two other suites. Move awaitPrompts into shared test support, parameterized by the backend type or a prompt-count closure, and use it from all three suites.
- [x] `Tests/FoundationModelsRouterTests/RunMessageDeliveryTests.swift:141` `reuse/reuse` — The new pumpStops helper repeats a helper that already exists in another test suite. Two copies can drift apart, and a fix to one does not reach the other. Move pumpStops to one shared test support location, such as Tests/FoundationModelsRouterTestSupport, and call it from all three suites.
