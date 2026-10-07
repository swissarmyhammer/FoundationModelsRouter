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
position_column: doing
position_ordinal: '80'
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