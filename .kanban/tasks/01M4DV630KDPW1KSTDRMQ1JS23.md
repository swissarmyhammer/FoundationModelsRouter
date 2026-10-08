---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4dv7215tzd4mt7989vcebcw
  text: |-
    ## Extras dependency and final names

    This task depends on Extras task 01M4DV675C3BNZHBNFNPFQFMJT (FoundationModelsExtras board, not this board). That task is not implemented yet. Do not start this task before that Extras change is available.

    Final names from the Extras session:

    - `public struct PlanSnapshot: Sendable, Codable, Equatable` (FoundationModelsExtras, OperationEvents/PlanSnapshot.swift). Fields: `id: String`, `entries: [PlanSnapshot.Entry]`. `entries` is always the full list. An update replaces the plan that has the same `id`.
    - `PlanSnapshot.Entry`: `content: String`, `priority: PlanSnapshot.Priority`, `status: PlanSnapshot.Status`.
    - `PlanSnapshot.Priority`: `.high`, `.medium`, `.low`.
    - `PlanSnapshot.Status`: `.pending`, `.inProgress` (raw value "in_progress"), `.completed`, `.cancelled`.
    - `OperationEvent.plan: PlanSnapshot?`. It is the last init parameter. Its default is nil. Only `.progress` events set it. An old record that has no `plan` key decodes as nil.
    - `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil)`. `detail` stays a short text line for the model. The model must never get `plan`.
    - There is no new `OperationEventKind`.

    Note for step 4: a plan update replaces the plan that has the same `id`. Thus the restore path must replay the last plan for each plan `id`.
  timestamp: 2026-10-08T13:28:33.061708+00:00
- actor: claude-code
  id: 01m4dw0ex1s9xg8gz5hsp3d907
  text: |-
    ## Extras dependency is satisfied

    The Extras plan work is on FoundationModelsExtras origin/main. The feature commit is ee4a798. Extras main is now 5c1c638. It adds `PlanSnapshot`, `OperationEvent.plan` and `ToolContext.progress(_:plan:)`. The names are the same as in the comment above. Before you start, update the Extras package dependency of Router to a revision at or after 5c1c638.
  timestamp: 2026-10-08T13:42:25.441037+00:00
- actor: claude-code
  id: 01m4dy0k494emggzrf5fxsfn9t
  text: |-
    ## Research results

    ### Extras dependency
    - Package.swift uses `branch: "main"` for FoundationModelsExtras. `swift package update FoundationModelsExtras` moved Package.resolved and IntegrationTests/Package.resolved from 50fd4a5 to 5c1c638. Both Package.resolved files are in .gitignore, so git shows no diff for them. IntegrationTests/Package.swift does not pin Extras directly. No change to Package.swift is necessary.

    ### Which `tool` name code-mode `tools.*` events carry (step 3)
    - A synchronous nested `tools.*` call of code mode gets its own ToolContext (inner tool name, inner token). But its events go through `MountedRunUpstreamSink.post(event:)` to the outer context, and `ToolContext.post(_:)` stamps them again with the outer `tool`, `op` and `completionToken`.
    - Result: the events have `tool == "runCode"` (`MultiTool.name`) and `correlationID ==` the token of the outer runCode run. The plan and the detail stay.
    - Exception: an inner tool that declares a background mount posts to the session sink with its own name and token.
    - Thus one runCode run can post text progress (for example shell output) and plan progress under the same `(tool, correlationID)` key. The merge key must include "has a plan".
    - Sources: FoundationModelsMultitool RunBinding.invoke(_:arguments:journalOp:); Extras ToolContext.mount(_:op:as:), ToolRun.init, MountedRunUpstreamSink.post(event:), ToolContext.post(_:).

    ### Model input paths for `plan` (step 2)
    - Preamble: `OperationEventSegment.renderedLine(for:)` uses only `detail` (or the elicitation message). The live LanguageModelSession gets only that text.
    - The structured OperationEventSegment on a recorded `.prompt` entry: the MLX TranscriptConverter reads only text segments of a prompt, so no leak.
    - LEAK FOUND: the run journal writes `.toolOutput` entries whose structured segment holds the full OperationEvent JSON. On restore, `TranscriptTree.effectiveTranscript(forSession:)` puts these entries into the seed transcript of the backend, and the MLX TranscriptConverter sends `.structure` tool-output content as JSON (`structuredSegment.content.jsonString`). Thus after a restore, the `plan` goes into model input. The fix must remove `plan` from the seed transcript, and keep it on disk.
    - Compaction (`Summarization.render`) uses only text segments, so no leak there.

    ### Durability (step 4)
    - `OpenProgressRow.accepts(_:)` admits each progress event of the same run. A plan event must not go into the open row.
    - Restore reads the journal with `TranscriptEvent.operationEvents`, which decodes the full OperationEvent JSON, so `plan` stays readable after restore. `lostRunTerminalEvents(in:)` makes a `.completed` event, which never has a plan; that is correct.
  timestamp: 2026-10-08T14:17:26.921341+00:00
- actor: claude-code
  id: 01m4dz41x4d04t56vbwe0yj8x2
  text: |-
    ## Implementation landed (not committed)

    - Step 1, live delivery: added `SessionEvent.runProgress(OperationEvent)`. `RoutedSessionActorRunJournal.record(event:)` now delivers each recorded event live through `liveEvent(for:)`, an exhaustive switch on `OperationEventKind`. A progress event that goes into the open progress row is also delivered live. New case added to the switches in SessionAnswer, SessionProjection, ScriptedToolAnswerComparisonTests, Examples/MultiModelGeneration and IntegrationTests RealToolAnswerComparisonTests.
    - Step 2, plan out of model input: `renderedLine(for:)` already used only `detail` (a test now holds this). The one leak was the restore seed: `TranscriptTree.effectiveTranscript(forSession:view: .restore)` now maps each entry through the new `OperationEventSegment.removingPlans(from:)` (`.prompt` and `.toolOutput` entries; `withoutPlan` keeps the segment id and every other field). The disk keeps the plan, so `TranscriptEvent.operationEvents` still reads it.
    - Step 3, merge rule: `SessionOutbox.stage` uses `progress(_:replaces:)`, whose key is tool + correlationID + "has a plan". The code-mode answer is in the research comment: `tool == "runCode"` and the outer run token.
    - Step 4, durability: `OpenProgressRow.accepts(_:)` refuses an event that has a plan, so the journal writes it at once as its own row. Restore path examined: the lost terminal is a `.completed` event with no plan and the detail of the newest event.
    - Docs: SessionEvent.runProgress doc, RoutedSession.md bullet, generation-queue.md bullet.
    - Tests: RunProgressDeliveryTests (7), PlanRestorationTests (4), SessionOutboxTests (+2), helper PlanFixtures.
    - RED seen for: merge tests, live delivery tests, plan durability tests, restore seed tests. The rendered-line test, the next-prompt test, the restore-reads-the-last-plan test and the lost-terminal test passed at once: they hold behavior that was correct already. The prompt-entry unit test of `removingPlans(from:)` was written after the code.
    - Not changed: no public `PlanSnapshot` typealias was added to OperationVocabulary.swift, because the card does not ask for it. A consumer reads `OperationEvent.plan` through `import FoundationModelsExtras`.
  timestamp: 2026-10-08T14:36:48.932303+00:00
- actor: claude-code
  id: 01m4dz48zy8x7gce2jeecywaf3
  text: |-
    ### implement — changed
    - evidence: 19 files — Sources: SessionEvent.swift, RoutedSessionActorRunJournal.swift, OpenProgressRow.swift, SessionOutbox.swift, OperationEventSegment.swift, TranscriptReconstruction.swift, SessionAnswer.swift, SessionProjection.swift, FoundationModelsRouter.docc/RoutedSession.md; Tests: RunProgressDeliveryTests.swift (new), PlanRestorationTests.swift (new), Helpers/PlanFixtures.swift (new), SessionOutboxTests.swift, ScriptedToolAnswerComparisonTests.swift; Examples/MultiModelGeneration/main.swift; IntegrationTests RealToolAnswerComparisonTests.swift; generation-queue.md; Package.resolved and IntegrationTests/Package.resolved moved to Extras 5c1c638 (both are git-ignored). `swift test`: 1544 tests in 194 suites passed, 0 failures, 2 known issues that were there before; no compiler warnings in the changed files; `swift build --package-path IntegrationTests --build-tests` builds.
    - next: /review. Task stays in doing. Nothing is committed.
  timestamp: 2026-10-08T14:36:56.190776+00:00
- actor: claude-code
  id: 01m4dzc2v4pfvntnvggekhd65t
  text: |-
    ### test - green
    - evidence: `swift test` - 1544 tests in 194 suites passed, plus 23 and 19 tests in the two other runs, 0 failed, 0 skipped. 2 known issues are expected (withKnownIssue) in RealModelHarness.swift and BoundedWait.swift, which this task did not change. `swift build --build-tests --package-path IntegrationTests` - build complete. No compiler warning in the changed code.
    - formatter: the repo holds no .swiftformat, .swift-format or .swiftlint.yml, and Package.swift has no Airbnb plugin. With tool defaults, 346 of 412 unchanged files also fail `swiftformat --lint`. So no repo rule exists and no file was reformatted.
    - next: review.
  timestamp: 2026-10-08T14:41:12.036334+00:00
- actor: claude-code
  id: 01m4dzr9wnqvdy2qnhjg743hhf
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (checkpoint 1d3d6f82): 1 finding (1 confirmed, 5 refuted) — Sources/FoundationModelsRouter/Session/SessionEvent.swift:174 (completeness/invariant-propagation)
    - next: Correct the finding in the 2026-10-08 09:41 Review Findings section. Make the outbox merge key and the SessionEvent plan-replacement documentation agree, and add a test with two plans of different ids before one submission. The task stays in review.
  timestamp: 2026-10-08T14:47:52.469992+00:00
- actor: claude-code
  id: 01m4dzrtgh8hfxyph4hqdfy5ea
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 19 files
    - test: green — swift test, 1544 tests in 194 suites passed, 0 failed; IntegrationTests build complete
    - commit: 1d3d6f82
    - review: findings — Sources/FoundationModelsRouter/Session/SessionEvent.swift:174
  timestamp: 2026-10-08T14:48:09.489349+00:00
- actor: claude-code
  id: 01m4e02n1xv3m7j3x1ceqthr1v
  text: |-
    ## Finding fix: plan id in the outbox merge key

    - Decision: the merge key follows the Extras contract ("An update replaces the plan that has the same id"). The `SessionEvent.runProgress` doc already said this, so the code moved to the doc, not the doc to the code.
    - `SessionOutbox.progress(_:replaces:)` now compares `older.plan?.id == newer.plan?.id` in place of "has a plan". The key is tool + correlationID + plan id. A text progress has a nil plan id, so text still replaces only text, and a plan never replaces text.
    - The cause was the "has a plan" wording at several sites. These now say "per plan id" or "the last plan of each plan id": the SessionOutbox type doc and merge-key doc, RoutedSessionActorRunJournal.record(event:) doc, OperationEventSegment.withoutPlan doc, TranscriptTree.effectiveTranscript doc, RoutedSession.md, generation-queue.md, the PlanRestorationTests header.
    - Durability and restore already agree with per-id semantics: OpenProgressRow.accepts(_:) refuses each event that has a plan, so the journal writes every plan event to disk, whatever its id. PlanRestorationTests.theLastPlanOfEachIdIsOnDiskAfterARestore already holds the last plan of each id. No code change was necessary there.
    - Tests: SessionOutboxTests.plansOfDifferentIdsPendSeparately (two ids before one take: both stay) and planReplacesOnlyThePlanOfTheSameId (id 1, id 2, id 1 again: [newer id 1, id 2]). RED seen for both before the fix (the second plan replaced the first). `PlanFixtures.secondPlanID` now holds "plan-2"; PlanRestorationTests uses it in place of its own private copy.
  timestamp: 2026-10-08T14:53:31.581642+00:00
- actor: claude-code
  id: 01m4e02sb2ft322508hrqsndfs
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Session/SessionOutbox.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift, Sources/FoundationModelsRouter/Session/OperationEventSegment.swift, Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift, Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md, generation-queue.md, Tests/FoundationModelsRouterTests/SessionOutboxTests.swift, Tests/FoundationModelsRouterTests/Helpers/PlanFixtures.swift, Tests/FoundationModelsRouterTests/PlanRestorationTests.swift. `swift test`: 1546 tests in 194 suites passed (plus 23 and 19 in the other two runs), 0 failures, 2 known issues that were there before (RealModelHarness.swift, BoundedWait.swift). No compiler warning. The one SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" is a build-graph note of the mlx dependency and is not from this change. Finding SessionEvent.swift:174 is checked.
    - next: /review. Task stays in doing. Nothing is committed.
  timestamp: 2026-10-08T14:53:35.970443+00:00
- actor: claude-code
  id: 01m4e06k1dv219zktcy58jza5q
  text: |-
    ### test — green
    - evidence: swift test — 1546 tests in 194 suites passed, 0 failed, 0 skipped. Two more runs (23 and 19 tests) also passed. 2 known issues exist; both are expected-failure tests that were there before this task (RealModelHarness embedding slot, BoundedWait never-holds wait). swift build --build-tests --package-path IntegrationTests — Build complete.
    - warnings: only "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It comes from the build system and a dependency bundle. No Swift warning comes from the changed code.
    - next: review
  timestamp: 2026-10-08T14:55:40.589995+00:00
position_column: doing
position_ordinal: '80'
title: Send .progress operation events live as SessionEvent.runProgress and keep the plan out of the model text
---
## Origin

The FoundationModelsACPAgent session sent this request. The user approved the design. A tool must send one-way updates through Router and the ACP agent to the client, in the same way as elicitation. The first use is an ACP agent plan (https://agentclientprotocol.com/protocol/v2/agent-plan).

## Dependency

This task depends on the Extras base task (session foundationmodelsextras-98). That task adds:
- a `PlanSnapshot` type (id, full list of entries with content, priority and status),
- the field `OperationEvent.plan: PlanSnapshot?`,
- `ToolContext.progress(_ detail: String, plan: PlanSnapshot? = nil)`.

The Extras session will send the final names. Use those names. Do not start before the Extras change is available. The ACP agent task depends on this task.

## Steps

1. Live delivery.
   - Add `SessionEvent.runProgress(OperationEvent)`.
   - In `RoutedSessionActorRunJournal.record(event:)` (near line 36), call `deliverLive(.runProgress(event))` for each `.progress` event. Do this in the same way as for `.message` and `.elicitation`. Now Router writes `.progress` to the journal, but it does not send it live.
   - Add the new case to each exhaustive switch (SessionProjection.swift:183, SessionAnswer.swift:182, and all other switches that the compiler shows).
2. Keep the plan out of the model text.
   - `OperationEventSegment.renderedLine(for:)` (near line 39) must use only `detail`. It must never use `plan`.
   - Examine every other path that changes a pending event into model input. Make sure that no path puts `plan` into model input.
3. Merge rule (SessionOutbox.swift:75-83).
   - Now a progress event replaces the older event that has the same `tool` + `correlationID`.
   - Add "has a plan" to that key. Then a plan replaces only an older plan, and text progress replaces only older text progress. One code-mode run can send both shell output and a plan.
   - Find which `tool` name the events of a code-mode `tools.*` call carry. Record the result on this card.
4. Durability.
   - The open progress row is in memory only (RoutedSessionActorRunJournal.swift:22-25).
   - A progress event that has a plan must go to disk immediately. It must not stay in the open row. Then session/load can replay the last plan.
   - Examine the restore path (SessionTreeRestoration.swift:411 and 606) with `plan` set. Make sure that restore keeps the plan.

## Acceptance

- A `.progress` event goes live to the client as `SessionEvent.runProgress`.
- No model input contains plan data.
- A plan event and a text progress event of the same tool and correlation ID do not replace each other.
- After a restore, the last plan is available for replay.
- Tests cover each item above.

## Review Findings (2026-10-08 09:41)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 15 file(s) reviewed, 4 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md` — no validator matches this file
> - `generation-queue.md` — no validator matches this file

- [x] `Sources/FoundationModelsRouter/Session/SessionEvent.swift:174` `completeness/invariant-propagation` — The documented contract says a plan replaces only the earlier plan with the same `PlanSnapshot.id`. The outbox merge key ignores the plan id, so a plan with a new id replaces the pending plan event of the same run and tool. The two sites disagree on what a plan replacement means. Either add the plan id to the merge key in `progress(_:replaces:)` so it matches the documented contract, or change the `SessionEvent` doc to say a plan replaces any earlier pending plan of the same run. Add a test with two plans of different ids posted before one submission.