---
assignees:
- claude-code
depends_on:
- 01M3FNBZF74DHSGE70C5339RGT
- 01M3FNC92WA10NG6TX59H3RKXF
- 01M3FNK00PYXP7E102NWNHMD56
position_column: todo
position_ordinal: a380
title: 'Router: remove Hosting/ and use the tool hosting in FoundationModelsExtras'
---
## What
Decision (2026-09-26): the core `FoundationModelsExtras` target owns tool hosting, both the interface and the implementation (user: a split between Extras and the router is messy). The router makes, manages, compacts and transcribes sessions, and uses Extras for tool hosting. The multitool then uses tool hosting with no dependency on the router.

Blocked by the Extras tasks (Extras board), in this order: 01M3FP9700G1GWA15B0GEZQGMD, 01M3FP9FGARYJFK9NYQMRY5QM0, 01M3FP9WTFQEQZ8Q4YJDXRA4D9, 01M3FPA83C04HNESZYBEBTPRDG. Also blocked by the follow-up Extras task 01M3GBW53WH4J85BXA0WZQB1Q8. Pin its Extras commit, 11404f3, in the same change that removes `Hosting/`. Extras then has public `ToolContext`, `BackgroundTool`, `ToolMount` and other types with the router's names, so a pin without the removal makes the names ambiguous for a user that imports both modules.

Extras name change: the router's internal actor `SessionMailbox` is `RunPlane` in Extras. `SessionMailbox.makeCompletionToken()` becomes `RunPlane.makeCompletionToken()`.

- Remove `Sources/FoundationModelsRouter/Hosting/` (18 files), except `OperationVocabulary.swift` if Extras task 01M3FPA83C04HNESZYBEBTPRDG leaves it in the router.
- Remove the types that moved with it: `Tracing/ToolCallSpan.swift`, `Session/ToolResultAppendBoundary.swift` (`ToolResultAppend`, `ToolResultAppendBoundary`), `ToolCallReport` from `Session/SessionEvent.swift`, and the protocols `BackgroundRunSettlementObserver` and `ToolCallReportSink` (`Session/OperationEventJournal.swift`) and `StagedEventWithdrawing` (`Session/SessionOutbox.swift`). `OperationEventJournal` and `SessionOutbox` keep their conformances to the Extras protocols.
- Change each router file that uses these types to use the Extras types (`RoutedLLM.makeSession` makes the Extras `RunPlane` for each session; the `RoutedSessionActor*` files use the Extras `ToolContext`).
- Public router names such as `ToolContext`, `BackgroundTool`, `ToolMount`, `SubmissionBoundaryTool` and `LostRunError` must stay usable by router users. The name-clash guard test (from task 01M3FNB4MCRRBTJNNVZZ6P02R2) must compile.
- Router tests: a test of a moved internal type (for example `BackgroundToolRunnerTests`, `RunToCompletionRunnerTests`) that cannot reach the type with `@testable import FoundationModelsRouter` is removed, because Extras has a copy. A test that tests router behavior through `RoutedSession` stays and must pass with no change to what it asserts.
- Update `README.md` and the DocC articles that describe tool hosting: tool hosting is in Extras.
- Extras decision (2026-09-26): the Extras hosting code does not use `RaceGate`. It uses a run-plane `start(…, body:)`, the run-plane `wait(completionToken:seconds:)` for the inline grace, a stored `Task` for the stop report, and an internal `Promise` for the timeout race. One change in behavior: a cancel during the inline grace wait now returns the pending envelope at once. If a router test asserts the old behavior, update the test for the new behavior and record it in the task comment. Do not change a test for any other reason.
- Final Extras API (2026-09-26, Extras commit fa43d18 or the follow-up commit that the Extras session names):
  - PIN: Extras commit 11404f3 (Extras task 01M3GBW53WH4J85BXA0WZQB1Q8). It replaces fa43d18.
  - `RunPlane` public members: `init`, `makeCompletionToken`, `attach(settlementObserver:)`, `backgroundRuns`, `settledRunTokens`, `respond`, `complete`, `sweep`, `wait(completionToken:seconds:)`. `start(tool:op:kind:completionToken:canceler:body:)`, `RunPlane.StartResult` and `updateProgress(completionToken:detail:)` are `@_spi(Testing) public`.
  - There is no `track(... settling:)`. A router test that called `mailbox.track(..., settling: Task { ... })` (`BackgroundRunTranscriptTests.swift:287, 333`, and others) calls `start(..., body: { ... })`: the body returns the terminal `OperationEvent`, and a `nil` canceler cancels the body task. This is a change to how the test starts a run, not to what it asserts.
  - `@testable import` does not give access to `@_spi` members. A test file that uses `@testable` and calls `start` or `updateProgress` needs `@_spi(Testing) @testable import FoundationModelsExtras`.
  - `PendingRunEnvelope.decoded(fromRendered:)` is now `makeDecoded(fromRendered:)`: change `Session/ToolOutputCapping.swift:113`. `replacing(detail:)` is public.
  - `ToolResultAppendBoundary` is a struct made with a closure: change `RoutedSessionActorAnswerExecution.swift:677` to `ToolResultAppendBoundary { await self.noteToolResult($0) }` (use the router's current method name).
  - `ToolCallReport.init?(closing:attachments:)` is public; `OperationEventJournal.postToolCallReport` keeps using it. `ToolCallSpan` is internal in Extras; the router removes its own copy with `Hosting/`.
  - `OperationVocabulary.swift` stays in the router.
  - `SerialAsyncChain` is public in Extras; use it and remove the router copy.
  - Tested behavior changes in Extras: a cancel during the grace wait returns the pending envelope at once; a second stop waits for the first stop and does not run the canceler again.
- The Extras task of each hosting part lists the router tests that did not move because they need a `RoutedSession`. Those tests stay in the router.
- After this task, remove `Concurrency/RaceGate.swift` and `Concurrency/SerialAsyncChain.swift` from the router if no router code uses them.
- Keep the cancellation invariants. Do not simplify code that looks redundant in the pump or the outbox.

## Acceptance Criteria
- [ ] `Sources/FoundationModelsRouter/Hosting/` has no tool-hosting types (only `OperationVocabulary.swift` if it stays).
- [ ] No router file declares `ToolContext`, `BackgroundTool`, `ToolMount`, `ToolRun`, `BackgroundToolRunner` or `RunToCompletionRunner`.
- [ ] Add a name-clash guard test file, for example `Tests/FoundationModelsRouterTests/ExtrasNameClashTests.swift`, that imports both `FoundationModelsRouter` and `FoundationModelsExtras` and uses each public name that both modules had (for example `ModelRef`, `ModelPool`, `GenerationQueue`, `MessageID`, `ToolContext`, `BackgroundTool`, `ToolMount`, `SubmissionBoundaryTool`, `LostRunError`). It compiles with no ambiguity. (Moved here from task 01M3FNB4MCRRBTJNNVZZ6P02R2, because the router builds against the Extras head, which already has all these names.)
- [ ] The router examples and `IntegrationTests/` compile.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] The router tests of tool behavior through sessions pass with no change to what they assert (for example `SessionOutboxToolWiringTests`, `BackgroundRunFixtures` users, `RespondRunPlaneDrainTests`, `RoutedSessionToolContextBindingTests`, `ToolOutputCappingTests`, `SessionTreeRestorationLostRunTests`, `PendingEventInjectionTests`).
- [ ] Run the cancellation and background-run tests with parallel repetitions (for example `swift test --filter AnswerCancellation --parallel --num-workers 8`, 20 times), and all runs pass.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #cross-repo