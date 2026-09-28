---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3m3nyy15gqdcqy7r9k13nb7
  text: |-
    ### Research and first decisions (implement, iteration 1)

    - The Extras checkout is at 4a733cd (origin/main). It contains the pin 11404f3. `Package.resolved` is ignored by git, and `Package.swift` follows `branch: "main"`, so this repository has no pin line to change. The resolved revision is the pin.
    - Difference from the task text: the Extras `RunPlane.start` and `updateProgress` are `@_spi(Testing) public`, as the task says. `RunPlane.cancel(completionToken:)`, `awaitAnswer`, `pendingElicitationIds` and `waiterCount` are INTERNAL in Extras (the router had them internal too). A router test reaches them only with `@testable import FoundationModelsExtras`.
    - Difference from the task text: `ToolCallReport.init?(closing:attachments:)` is public in Extras, but the `OperationEventSink.postToolCallReport(closing:attachments:)` extension is internal in Extras. No router code calls it after the removal, so the router removes its copy.
    - Difference from the task text: `MountSite`, `ToolMounting.makeWrapped(tool:site:configuration:)`, `ToolFailureDelivery` and `ToolDecorator` are public in Extras. `BackgroundToolRunner`, `RunToCompletionRunner`, `ContextBindingTool`, `ToolRun`, `RunEventFunnel`, `ToolCallSpan` and the failure-delivery tools are internal in Extras.
    - Difference from the task text: 4a733cd adds `BackgroundTool.mount(for:)` and `ToolMounting.call(_:arguments:site:mount:)`, which decides the mount for each call.
    - Decision: the public router names are public typealiases in `Hosting/OperationVocabulary.swift` (the same pattern as `ModelPool` and `OperationEvent`): `ToolContext`, `BackgroundTool`, `ToolMount`, `ToolMountError`, `SubmissionBoundaryTool`, `LostRunError`, `RunKind`, `BackgroundRun`, `WaitOutcome`, `CancelOutcome`, `PendingRunEnvelope`, `ToolCallAttachment`, `ToolCallReport`, `ElicitationAnswerDelivery`, `ElicitationCompletionDelivery`. No `@_exported import`.
    - Decision: the session property keeps the name `mailbox`; only its type changes from `SessionMailbox` to the Extras `RunPlane`. Thus the router tests that read `session.mailbox` keep their access path.
    - Extras has copies of these router test files in `Tests/FoundationModelsExtrasTests/Hosting/`: BackgroundToolRunnerTests, DeclaredRunKindTests, PendingRunEnvelopeTests, RunPlaneTests, RunPlaneActorTests (the copy of SessionMailboxTests), RunToCompletionRunnerTests, ToolContextMountTests, ToolContextTests, ToolContextTokenPublicSurfaceTests, ToolFailureDeliveryTests, ToolMountingTests, LostRunErrorTests, ToolCallSpanTests, ToolResultAppendTests.
  timestamp: 2026-09-28T13:36:14.785964+00:00
- actor: claude-code
  id: 01m3m851aq56prpp72r5vq7h0r
  text: |-
    ### Implementation record (iteration 1)

    **Sources**
    - Removed `Hosting/` (all files except `OperationVocabulary.swift`), `Tracing/ToolCallSpan.swift`, `Session/ToolResultAppendBoundary.swift`, `Concurrency/RaceGate.swift` and `Concurrency/SerialAsyncChain.swift`. `SessionOutbox` now uses the Extras `SerialAsyncChain`.
    - `SessionMailbox` is now the Extras `RunPlane`. The session property keeps the name `mailbox`.
    - `ToolMounting.makeSessionMounted(...)` is now a router extension over the public Extras `ToolMounting.makeWrapped(tool:site:configuration:)` with `MountSite`. It keeps its name and parameters; the parameter `mailbox` has the type `RunPlane`.
    - The ambient `ToolContext` uses `runPlane:`. The boundary is `ToolResultAppendBoundary { await self.noteToolResult($0) }`.
    - Dead code removed, as the Extras hosting now opens the tool span: `RouterTracing.SpanName.tool`, `AttributeKey.toolName/toolRunKind/toolOutcome`, `RouterTracing.ToolRunKind`, and `ULID.stringLength`. Periphery with `--retain-public` over Sources now reports only the known `import MLXLLM` false positive.
    - The DocC member links to Extras types (for example ``ToolContext/elicit(_:)``) are now plain code spans, because a link through a typealias to another module does not resolve.

    **Docs**
    - `README.md` has the new section "Tool hosting comes from FoundationModelsExtras".
    - `RoutedSession.md` states that the hosting is in Extras and that the router names are aliases.

    **Tests (sub-agent)**
    Removed files. Each has an Extras copy in `Tests/FoundationModelsExtrasTests/Hosting/` with the same test function names, except the renames listed below:
    - BackgroundToolRunnerTests
    - DeclaredRunKindTests
    - PendingRunEnvelopeTests
    - RunPlaneTests
    - RunToCompletionRunnerTests
    - ToolContextMountTests
    - ToolContextTests
    - ToolContextTokenPublicSurfaceTests
    - ToolFailureDeliveryTests
    - ToolMountingTests
    - LostRunErrorTests
    - SessionMailboxTests (its Extras copy is RunPlaneActorTests)

    Extras copies with a new name:
    - `track{ListingAndWaitLifecycle,RefusesDuplicateToken,ForwardsTheSettledTerminalOnce,ForwardsNothingForASweptRun}` -> `start...`
    - `publishedMintMatchesTheMailboxTokenShape` -> `theContextTokenHasTheRunPlaneTokenForm`
    - `eachCallMintsADistinctToken` -> `eachCallMakesADistinctToken`
    - `theConsumerExpressionFallsBackToAFreshMint` -> `theConsumerExpressionFallsBackToANewToken`
    - `factoryInheritsMailboxAndSessionIdentity` -> `factoryInheritsRunPlaneAndSessionIdentity`

    The "no Extras copy" list is empty.

    Router-behavior tests kept:
    - `SessionRunPlaneTests.swift`: the close-sweep tests (3), the restore test and `forkGetsFreshMailbox`.
    - `SessionMountCompositionTests.swift`: 4 mount tests from ToolMountingTests, 2 `makeSessionMounted` tests from ToolFailureDeliveryTests, and 3 token-capping and withdraw tests from BackgroundToolRunnerTests.

    Mechanical change classes:
    1. `SessionMailbox` -> `RunPlane`.
    2. `track(settling:)` -> `start(..., body:)`.
    3. `ToolContext(mailbox:)` -> `ToolContext(runPlane:)`.
    4. The runner and `makeWrapped` calls take `site: MountSite(...)`.
    5. Imports added: plain, `@testable` or `@_spi(Testing)` `FoundationModelsExtras`.
    6. ToolTracingTests: a named constant `"FoundationModelsRouter.tool"` replaces the removed `SpanName.tool`.

    Other test changes:
    - RegisteredJournalOpTests: `makeWrapped(tool:inheriting:...)` is now the public `host.mount(_:op:as:postingTo:)`.
    - The shared helpers `eventually` and `formRequest` moved to `Helpers/PendingElicitationFixtures.swift`.
    - ToolMountFixtures: the members that no test uses any more are removed.
    - `ExtrasNameClashTests.swift` was added. Two compile fixes: the key is `ModelPoolKey(ref:role:)`, and `MessageID` has no public init.

    Extras behavior changes that a test had to follow: none. The tests of the two changed behaviors were in removed files, and their Extras copies cover them.

    **Differences from the task text**
    - The pin: `Package.resolved` is ignored by git, and `Package.swift` follows `main`, which resolves to 4a733cd. That revision contains 11404f3.
    - `ToolCallReportSink`, `postToolCallReport` and `BackgroundRunSettlementObserver` are Extras protocols now. The router has no copy of them.
    - `RouterTracing` tool-span names are removed, because the Extras hosting opens that span with the same names.

    **Verification**
    - Clean build: `swift package clean && swift build --build-tests` gives "Build complete!". It shows zero warnings from this package. The only warnings are the vendored mlx-swift C++17 warnings, the SwiftPM manifest-cache "disk I/O error" warnings, and the known mlx bundle "missing creator" warning.
    - `swift test`, 3 runs in a row. Each run passed, with exit 0:
      - "1352 tests in 169 suites passed ... with 2 known issues"
      - "17 tests in 8 suites passed"
      - "19 tests in 3 suites passed"
      - XCTest: "Executed 0 tests" three times
    - `swift test --filter AnswerCancellation --parallel --num-workers 8`, 20 runs: each run had exit 0 and "27 tests in 1 suite passed".
    - `swift build --build-tests --package-path IntegrationTests` builds (sub-agent run).
    - The executable targets build as part of `swift build`.
    - NOT DONE: the 10 repeated parallel runs of each of the background-run, outbox and hosting suites. The user stopped that step and does not want the repeated runs. Each of those suites passed in the 3 full runs.
  timestamp: 2026-09-28T14:54:23.063603+00:00
- actor: claude-code
  id: 01m3m854sss96bxpsaaq2qn3jv
  text: |-
    ### implement — changed
    - evidence: Sources (Hosting/ removed except OperationVocabulary.swift; ToolCallSpan, ToolResultAppendBoundary, RaceGate, SerialAsyncChain removed; RoutedLLM, RoutedSessionActor*, ToolOutputCapping, CompactionYield, DiscoveryPriming, SessionOutbox, SessionEvent, OperationEventJournal, RouterTracing, ULID changed), README.md, RoutedSession.md, 12 test files removed, 3 test files added (ExtrasNameClashTests, SessionRunPlaneTests, SessionMountCompositionTests, plus the helper PendingElicitationFixtures), 25 test files changed, IntegrationTests PropagationProbeIntegrationTests. swift test 3x: 1352+17+19 tests pass each time; AnswerCancellation 20x: 27 tests pass each time.
    - next: test
  timestamp: 2026-09-28T14:54:26.617959+00:00
depends_on:
- 01M3FNBZF74DHSGE70C5339RGT
- 01M3FNC92WA10NG6TX59H3RKXF
- 01M3FNK00PYXP7E102NWNHMD56
position_column: doing
position_ordinal: '80'
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