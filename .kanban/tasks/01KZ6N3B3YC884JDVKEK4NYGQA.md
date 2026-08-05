---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7g708s06fy881v8x62nzav
  text: |-
    Research (picked up, moved to doing):

    - ElevatingTool/ToolContext/ToolElevation.wrapping already landed (deps ^vvg7ztt, ^b3arjr3) in Sources/FoundationModelsRouter/Hosting/. `ToolElevation.wrapping(_:sessionID:mailbox:sink:configuration:)` is the untyped entry point mirroring ToolOutputCapping.wrapping; non-String-output tools pass through unchanged.
    - The three composition sites today: RoutedLLM.swift instancedTools map (~line 208, connect → cap), RoutedSession.swift fork childTools map (~line 2008, fork → connect → cap; NOTE: childId is minted AFTER the map — must move `ULID.generate()` up so the child's ElevatingTool carries the child sessionID), SessionTreeRestoration.swift instancedTools map (~line 305, connect only).
    - Turn binding: every backend respond/stream (and compaction summarizer) call funnels through RoutedSessionActor.runCancellableModelCall(composedPrompt:_:) — the single seam to wrap `body(composedPrompt)` in `ToolContext.$current.withValue(...)`. Context: sessionID=id, mailbox, sink=outbox (SessionOutbox conforms OperationEventSink), fresh completionToken per turn, cancellation probe mirroring the model-call task's isCancelled (ToolContext doc forbids `{ Task.isCancelled }`-style read-side guessing).
    - Turn-riding preamble machinery already proven by PendingEventInjectionTests (composedPrompt + appendingOperationEventSegments + InMemoryRecorder assertions) — verify with an elevation-flavored end-to-end test, don't rebuild.
    - Test blast radius: elevation wraps every String-output tool, so existing casts on instanced tool lists break in SessionOutboxToolWiringTests, SessionTreeRestorationToolWiringTests, ToolOutputCappingTests (capping.wrapped now the ElevatingTool), AutoCompactionTests (`$0 is EchoTool`). ElevatingTool.wrapped must become internal (TokenCappingTool.wrapped precedent) for chain-order assertions.
    - Per-call clocks: fixtures conforming ElevationParameterProviding can return waitSeconds 0 to detach immediately — keeps the pending-envelope tests fast (no 5 s waits).
  timestamp: 2026-08-04T23:02:21.209777+00:00
- actor: claude-code
  id: 01kz7harkb64ddfsbk86xyq1at
  text: |-
    Implementation landed (TDD: 9 new tests written and watched fail before wiring; 3 more added from double-check findings, the cap-exemption one watched fail too).

    What changed:
    - ElevatingTool mounted at the three composition sites via `ToolElevation.wrapping(..., configuration: .nativeSessionMount)` (new `ElevationConfiguration.nativeSessionMount` = elevation on, stock 5 s wait / 120 s timeout, one definition for the mount policy), each site keeping its own distinct chain, documented in place:
      - RoutedLLM.swift makeSession: connect → elevate → cap
      - RoutedSession.swift fork: fork → connect → elevate → cap (childId now minted BEFORE tool composition so the child's ElevatingTool stamps the fork's own session identity)
      - SessionTreeRestoration.swift restore: connect → elevate (no fork, no cap)
    - Host-side ambient binding: `runCancellableModelCall` wraps `body(composedPrompt)` in `ToolContext.$current.withValue(...)` — sessionID = id, mailbox, sink = the session's SessionOutbox, stamps "session"/"respond", fresh per-turn completionToken, and a `ModelCallCancellationProbe` (Mutex-held task ref, bound right after the model-call Task is created) so `isCancelled` mirrors the model-call task verbatim rather than reading whichever task calls it.
    - Turn-riding verified, not rebuilt: end-to-end test drives elevate → pending envelope → gate opens → synthesized `.completed` into the outbox → next respond's composed prompt carries the preamble line and the recorded `.prompt` entry carries the durable OperationEventSegment.
    - Double-check findings, all four fixed:
      1. Turn-cancellation contract: pinned with a mount-level test (ToolInvokingBackend invokes the composed elevated tool inside respond; cancelCurrentTurn parks the run in the session mailbox and it later settles `.succeeded`), and `runCancellableModelCall`'s doc now states the elevated behavior (a cancelled turn detaches elevated in-flight tool calls — parked, individually cancellable via the mailbox, swept at close()).
      2. Doc-comment orphaning: stamps + probe class relocated above the doc block so it documents `runCancellableModelCall` again.
      3. "Envelope always survives the cap" was false under toolOutputLimit < ~16: `TokenCappingTool.call` now exempts a rendered `PendingRunEnvelope` (exact byte-shape check `PendingRunEnvelope.isRendered(_:)` sharing the rendering frame constants; new `ULID.stringLength`); test proves the envelope decodes intact under toolOutputLimit 5; all site comments corrected to cite the exemption.
      4. Probe true-path coverage: `CancellationObservingBackend` polls the ambient `isCancelled` inside respond and observes it flip after cancelCurrentTurn.
    - Existing tests updated to peel the new elevation layer (SessionOutboxToolWiringTests, SessionTreeRestorationToolWiringTests, ToolOutputCappingTests, AutoCompactionTests); `ElevatingTool.wrapped` made internal mirroring `TokenCappingTool.wrapped` for chain-order assertions.

    Verification: `swift test` → 715 + 18 + 12 tests, 0 failures, no compiler warnings (gated integration suites skipped as always).
  timestamp: 2026-08-04T23:21:53.003868+00:00
- actor: claude-code
  id: 01kz7hayhwwnw944nj2new9syz
  text: |-
    ### implement — changed
    - evidence: 11 files — Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Sources/FoundationModelsRouter/Core/ULID.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift, Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift (new), Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift; swift test 715+18+12 passed, 0 failures, 0 warnings
    - next: /review
  timestamp: 2026-08-04T23:21:59.100515+00:00
- actor: claude-code
  id: 01kz7kh4q04pw9h61a5ytphwpn
  text: |-
    ### review — findings
    - evidence: 22 findings recorded from `review sha HEAD~1..HEAD` (engine: 35 confirmed; 13 dropped under the review skill's pre-existing-test exception — AutoCompactionTests.swift:57/488/499/505, SessionTreeRestorationToolWiringTests.swift:35/72/113/126/131/159/175/187/213). Kept: SessionTreeRestoration.swift:311; RoutedSessionToolContextBindingTests.swift:76,102,144,174,193,199,232,242,248,252,260,262,277; SessionOutboxToolWiringTests.swift:282,734,780,828,851; SessionTreeRestorationToolWiringTests.swift:79; ToolOutputCappingTests.swift:351,468. Engine warning: RoutedSession.swift skipped by the duplication validator (over batch budget).
    - next: implement the 22 checklist items in the 2026-08-04 18:26 Review Findings section; task stays in review.
  timestamp: 2026-08-05T00:00:19.168580+00:00
- actor: claude-code
  id: 01kz7kn1mcssdxmq46dmpfx4mz
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 11 files (three elevated mounts, ToolContext binding at runCancellableModelCall, capping envelope exemption, RoutedSessionToolContextBindingTests new)
    - test: green — swift test, 745 passed, 0 failures, 29 expected gated skips
    - commit: 13a7048
    - review: findings — 22 recorded (engine 35 confirmed, 13 dropped per existing-tests rule): SessionTreeRestoration.swift:311 production duplication; RoutedSessionToolContextBindingTests.swift x13; SessionOutboxToolWiringTests.swift x5; SessionTreeRestorationToolWiringTests.swift:79; ToolOutputCappingTests.swift x2. Caveat: duplication validator skipped Session/RoutedSession.swift (over batch budget).
  timestamp: 2026-08-05T00:02:27.084428+00:00
- actor: claude-code
  id: 01kz7mjk5qw0f5sktg7sbyj1q2
  text: |-
    Working the 22 review findings (2026-08-04 18:26). Approach notes for the record:

    - Production duplication (SessionTreeRestoration.swift / RoutedLLM.swift): extracted internal `instanceToolsWithElevation(_:sessionID:outbox:mailbox:cappedToTokenLimit:)` on the `RoutedModel where Container == any LoadedLLMContainer` extension in RoutedLLM.swift; makeSession passes `budget?.toolOutputLimit`, restore passes `nil` (optionallyCapped(nil) adds no layer, so restore's connect → elevate chain is byte-identical). The fork site was deliberately left alone — it forks each tool before connecting, so it is not part of the duplicated pair the finding names.
    - New shared test helpers: Helpers/RouterTestFixtures.swift (StubProbe/StubMetadataSource/StubEmbeddingContainer/StubModelLoader + RouterTestFixtures enum: configJSON, treeJSON, rawMetadata, stubDimension, stubProbe, profile(context:), makeTempDir(prefix:), makeRouter(cacheDir:recorder:loader:)) and Helpers/ElevationTestHelpers.swift (type-erased `elevationWrapped(_:)` via a private ElevationLayerPeelable protocol + retroactive-in-module ElevatingTool conformance — erased so both wiring suites can share it despite each having its own private FakeToolArguments).
    - All existing per-file Stub* fixtures elsewhere in the test target are nested inside their suite structs, so the new top-level shared types collide with nothing; only the two files the findings name (RoutedSessionToolContextBindingTests, AutoCompactionTests) were migrated onto the shared fixtures.
    - Backend-coverage findings: grammar respond in ContextProbingBackend now captures the ambient ToolContext and posts progress (new test grammarRespondBindsToolContext, driven through makeGuidedSession(.ebnf) so the guided backend entry point is actually hit); CancellationObservingBackend.streamResponse captures the context at call time and polls isCancelled from the stream's production task (new test cancellingAStreamingTurnFlipsTheBoundProbe); poll loop magic numbers hoisted to named constants shared by both entry points.
    - SessionOutboxToolWiringTests: budgetWithSmallToolOutputCap and mailboxWaitTimeoutSeconds constants, ToolInvokingLLMContainer sync-invariant doc, new forkWithoutBudgetComposesConnectElevate test, makeRouter gained a defaulted recorder param so elevatedSlowToolCompletionRidesNextTurn no longer builds an inline Router with a duplicated StubProbe config.
    - ToolOutputCappingTests: both capping-only guards now also require `capping.wrapped is ElevatingTool<FakeToolArguments>`.

    swift test: 718 + 18 + 12 tests, 0 failures (3 new tests). The only build warning is the pre-existing mlx-swift Cmlx.bundle "missing creator for mutated node" build-system artifact, not a compiler diagnostic.
  timestamp: 2026-08-05T00:18:35.319662+00:00
- actor: claude-code
  id: 01kz7myj2q25y4qvhmzwrbz3x7
  text: |-
    Double-check verdict: REVISE — one defect found in the new test infrastructure, now fixed.

    Defect: CancellationObservingBackend's observation flags (respondStarted / observedCancellation / streamStarted / observedStreamCancellation) were plain `var Bool`s written from the model-call task (and the stream's production task) while the @MainActor test polls them concurrently — unsynchronized cross-executor access, and the class's "`@unchecked Sendable` on the same terms as ContextProbingBackend" doc was false (that invariant is "reads only after the turn returned", which the polling tests deliberately violate).

    Fix: all four flags are now `Mutex`-guarded (import Synchronization; the ModelCallCancellationProbe precedent) — private `Mutex(false)` backing storage with computed read accessors and `withLock` writes — applied to the whole class, not just the new streaming pair, and the class doc now states the invariant that actually holds (flags polled concurrently with the in-flight turn, mutex-synchronized; `inner` immutable and driven one call at a time).

    Everything else in the double-check passed: composition byte-identical at both extracted sites (optionallyCapped(nil) adds no layer), no leftover fixture references, no type collisions, new tests assert real behavior, all 22 findings addressed and checked. Re-ran: RoutedSessionToolContextBindingTests 6/6, then full swift test 718 + 18 + 12, 0 failures.
  timestamp: 2026-08-05T00:25:07.415622+00:00
- actor: claude-code
  id: 01kz7myqyxcfszqg25aytspb50
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/RoutedLLM.swift, Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift (new), Tests/FoundationModelsRouterTests/Helpers/ElevationTestHelpers.swift (new), Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift, Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift; all 22 review findings checked (22/22, 3 new tests); swift test 718 + 18 + 12, 0 failures
    - next: /review
  timestamp: 2026-08-05T00:25:13.437502+00:00
depends_on:
- 01KZ6N2KTSXX3VTHEJEVVG7ZTT
position_column: doing
position_ordinal: '80'
title: '[Router] Mount ElevatingTool for native sessions; bind ToolContext around respond'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"Elevation" (two mounts, one engine, two policies — this is the native mount) and §"The vocabulary and the host substrate" (Router binds the task local around native `respond()` also).

## What
- Insert `ElevatingTool` (elevation on, configured `waitSeconds` default 5 s) after `connecting(_:)` and inside whatever capping each site already applies. The three sites have deliberately different chains today — do NOT unify them; add only the elevation layer:
  1. `RoutedLLM.swift:204-208` (`RoutedModel.makeSession`): today `connect → cap`; becomes `connect → elevate → cap`.
  2. `RoutedSession.swift:1904-1909` (fork): today `fork → connect → cap`; becomes `fork → connect → elevate → cap`.
  3. `Recording/SessionTreeRestoration.swift:279-281` (restore): today `connect` only — no fork, no cap; becomes `connect → elevate`. Do not add fork or capping here.
  The pending envelope is tiny, so capping outside elevation is safe; document the per-site chains where the existing fork-then-connect rule is pinned.
- Bind the ambient context around native turns: `RoutedSessionActor`'s turn execution binds `ToolContext.$current.withValue(ctx)` around the backend `respond()`/stream calls, with the session's mailbox, upstream sink (the session's `SessionOutbox`), session identity, and cancellation. This is the host layer owning `window` — whether Apple's runtime propagates the task local into `Tool.call` is the propagation-probe task's question; the binding is correct either way, and `ElevatingTool` itself binds per-call around the inner call regardless.
- Native follow-up policy: no builtins on this path. A parked native call's completion arrives as a turn-riding event through the outbox at the next turn boundary — this already works via the existing drain/preamble machinery (`composedPrompt`, `appendingOperationEventSegments`) once the engine posts `.completed` to the connected sink; verify, don't rebuild.

## Acceptance Criteria
- [x] All three composition sites produce elevated tools, each preserving its real existing chain (wiring tests assert the three distinct per-site orders listed above, in the style of `SessionOutboxToolWiringTests`)
- [x] A slow fake tool invoked through a session's composed tool list returns the pending envelope to the model, and its later `.completed` event appears in the next turn's preamble and as a durable `OperationEventSegment`
- [x] A fork's parked runs live in the fork's own mailbox; parent unaffected
- [x] `swift test` green

## Tests
- [x] Extend `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift` (and restoration wiring twin) for the new elevation layer with per-site order assertions
- [x] New turn-riding-completion test with a scripted backend: elevate → pending envelope in rendered output → completed event drained into the following turn's composed prompt
- [x] `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-08-04 18:26)

> ⚠️ 1 file(s) not reviewed — the rendered prompt would exceed the agent's prompt cap:
> - `Sources/FoundationModelsRouter/Session/RoutedSession.swift` — 318962 rendered bytes, over the 280762-byte batch budget; not reviewed by: duplication (narrow the scope)

> Note: 13 engine findings were dropped under the review skill's written exception (their subject was refactoring/deduplicating/re-docstringing test code that already existed before this commit): AutoCompactionTests.swift:57/488/499/505 and SessionTreeRestorationToolWiringTests.swift:35/72/113/126/131/159/175/187/213.

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:311` — Tool instancing pattern with elevation is duplicated verbatim in RoutedLLM.swift at line 221, differing only by the sessionID variable (node.id vs sessionId) and whether output capping is applied. This is copy-paste code that should be extracted into a shared function. Extract a shared helper function in the RoutedModel extension (e.g. `instanceToolsWithElevation`) that both restore() and makeSession() call with appropriate parameters for sessionID and optional token cap limit, eliminating code drift risk.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:76` — The grammar-based `respond(to:following:grammar:maxTokens:)` method in ContextProbingBackend does not capture the ambient ToolContext, unlike the basic `respond(to:maxTokens:)` (line 49) and `streamResponse(to:maxTokens:)` (line 65) methods. The test file's docstring (lines 7-11) explicitly states that ToolContext should be bound 'around every backend `respond()`/stream call,' but this method just delegates without capturing or probing the context. Either (a) add ToolContext capturing and progress posting to the grammar-based respond method to match the basic respond method's pattern, or (b) document in the test file why the grammar variant intentionally does not participate in context binding.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:102` — `@unchecked Sendable` lacks a documented synchronization invariant. Mutable `lastBackend` property is exposed without explaining thread-safety. Add a synchronization invariant comment before the `@unchecked Sendable` declaration, e.g.: `/// @unchecked Sendable: mutable state is accessed only within a single-threaded test context.`.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:144` — The `streamResponse(to:maxTokens:)` method in CancellationObservingBackend does not interact with the ambient ToolContext, while ContextProbingBackend.streamResponse (line 65) DOES capture the context, and CancellationObservingBackend.respond(basic) (line 128) DOES poll the context. The test file's docstring (line 8) states that ToolContext should be bound 'around every backend respond()/stream call,' but this method just delegates without any context interaction. Add context interaction to CancellationObservingBackend.streamResponse for consistency. Either capture the context like ContextProbingBackend.streamResponse does, or poll context.isCancelled like respond(basic) does, to verify that the context binding propagates to the streaming path as stated in the test file's contract.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:174` — `@unchecked Sendable` lacks a documented synchronization invariant. Mutable `lastBackend` property is exposed without explaining thread-safety. Add a synchronization invariant comment before the `@unchecked Sendable` declaration, e.g.: `/// @unchecked Sendable: mutable state is accessed only within a single-threaded test context.`.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:193` — StubProbe reimplements an identical test utility that already exists in AutoCompactionTests.swift (lines 85-89). Both define the same MachineProbe stub with identical properties. Test utilities should be shared. Extract StubProbe to a shared test utilities module and import it in both test files.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:199` — StubMetadataSource reimplements an identical test utility that already exists in AutoCompactionTests.swift (lines 91-94). Both define the same MetadataSource stub with identical implementation. Test utilities should be shared. Extract StubMetadataSource to a shared test utilities module and import it in both test files.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:232` — configJSON fixture constant is identical to the one already defined in AutoCompactionTests.swift (line 128). The same JSON fixture data should not be duplicated across test files. Extract configJSON to a shared test fixtures module and import it in both test files.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:242` — treeJSON fixture constant is identical to the one already defined in AutoCompactionTests.swift (line 138). The same JSON fixture data should not be duplicated across test files. Extract treeJSON to a shared test fixtures module and import it in both test files.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:248` — rawMetadata computed property is identical to the one already defined in AutoCompactionTests.swift (line 144). Both construct RawRepoMetadata from the same fixture constants in identical ways. Extract rawMetadata to a shared test fixtures module and import it in both test files, or make it a static property in a shared utilities type.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:252` — profile constant hardcodes the same ProfileDefinition that AutoCompactionTests.swift defines as a parameterized function (lines 197-206). RoutedSessionToolContextBindingTests duplicates the profile definition without the context parameter instead of reusing or extending the existing pattern. Extract a shared profile factory or constant to avoid duplication. Either parameterize the profile in RoutedSessionToolContextBindingTests or create a shared utility that both files use.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:260` — stubDimension constant is identical to the one already defined in AutoCompactionTests.swift (line 148). Both are defined as `8` and serve the same purpose in test fixtures. This test constant should be shared. Extract stubDimension to a shared test fixtures module and import it in both test files.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:262` — makeTempDir() is a near-match to the identical function in AutoCompactionTests.swift (lines 208-213). Both create temporary test directories with the same logic; the only difference is the directory name prefix. This should be extracted to a shared test utility with a parameterized name. Extract makeTempDir to a shared test utilities module, parameterized by a test name string, or create a single shared version both files can use.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionToolContextBindingTests.swift:277` — Router construction pattern (lines 277-283) duplicates the initialization logic that AutoCompactionTests.swift extracts into a makeRouter() helper function (lines 215-223). Both create a Router with identical probe and metadataSource setup, differing only in loader and recorder. The pattern should be extracted to a shared test utility instead of inlining it. Extract a shared router factory function to a test utilities module that both files can use, parameterized by loader and recorder types to accommodate different test scenarios.
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:282` — `@unchecked Sendable` class `ToolInvokingLLMContainer` is missing a documented synchronization invariant explaining why concurrent access to `lastBackend` is safe. The rule requires either a lock/isolation mechanism or an explicit comment stating the invariant. Add a doc comment before the class definition (lines 280–282) explaining the synchronization invariant: that `lastBackend` is written once synchronously during `makeSession(instructions:tools:)` and read only by tests after the write completes, ensuring no concurrent access occurs.
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:734` — TokenBudget configuration is hardcoded with identical parameter values in three separate test functions. Repeated configuration values should be extracted to a named constant for maintainability and to avoid drift if the values need to change. Extract to a private static constant within the test class (e.g., `private static let testBudgetWithSmallCap = TokenBudget(limit: 4096, toolOutputLimit: 5)`) and reuse it in all three test functions.
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:780` — makeSession's composition is tested as budget-dependent: with budget (line 721) shows cap layer; without budget (line 753) shows no cap. But fork's structure is only tested when budget is present. If fork composition also varies by budget (as indicated by the parallel makeSession tests), the no-budget case should also be explicitly verified for layer structure, not just functional behavior. Add a test (e.g., `forkWithoutBudgetComposesConnectElevate()`) that creates a parent session without a budget, forks it, and explicitly verifies the child's tool structure is elevate→connect→fork→tool (no cap layer), parallel to line 753.
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:828` — The StubProbe configuration is hardcoded identically in two different functions. The same chip name, totalRAM, and recommendedMaxWorkingSetSize values are repeated and should be extracted to a named constant, or the new test should reuse the existing makeRouter helper function to avoid duplication. Either extract to a private static constant (e.g., `private static let stubProbe = StubProbe(chip: "Apple Test", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30)`), or better yet, use the existing makeRouter helper function at line 385 instead of creating the Router inline.
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:851` — The 30-second timeout value is hardcoded in three separate test functions. Timeouts are explicitly cited in the rule as configuration that should be named constants when repeated, to avoid maintenance issues if the value needs to change. Extract to a private static constant (e.g., `private static let mailboxWaitTimeoutSeconds: TimeInterval = 30`) and reuse it in all three test functions.
- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:79` — The `elevationWrapped` helper function is defined identically in both SessionOutboxToolWiringTests.swift and SessionTreeRestorationToolWiringTests.swift as part of this same change. Both cast a tool to `ElevatingTool<FakeToolArguments>` and return its wrapped property with identical logic. This shared test utility should be extracted to a common location rather than duplicated across test files. Extract `elevationWrapped` to a shared test utilities module or base test case that both test files import, rather than defining it separately in each file.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift:351` — The change adds verification that ElevatingTool wraps tools in composition chains (line 429-432: `let elevating = capping.wrapped as? ElevatingTool`), but this test of TokenCappingTool composition only verifies the capping layer, not the elevation layer inside it, even though the change purpose states ElevatingTool is mounted at all composition sites. Update line 366's guard to also verify that `capping.wrapped as? ElevatingTool<FakeToolArguments>` is non-nil, mirroring the composition check at line 429-432, to ensure ElevatingTool wraps the original tool in all capping scenarios.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift:468` — The change adds verification that ElevatingTool wraps tools in the fork composition chain (line 495-496: `(childActor.tools.first as? ElevatingTool<FakeToolArguments>)`), but this fork-with-capping test only verifies TokenCappingTool at the top level, not the elevation layer inside it. The change description states ElevatingTool is mounted at all composition sites, including fork with capping. Update the guard at line 468 to also verify that `capping.wrapped as? ElevatingTool<FakeToolArguments>` is non-nil after confirming TokenCappingTool, ensuring ElevatingTool wraps the child's tools in the fork-with-capping scenario. #phase-1 #router-first