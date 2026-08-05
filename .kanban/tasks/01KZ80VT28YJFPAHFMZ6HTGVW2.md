---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz89edxzbmwmstb8d6wvkhk0
  text: 'Picked up. Research so far: `ToolElevation.wrapping` (Hosting/ElevatingTool.swift) is called only from `ToolElevation.sessionMounted` (Session/ToolOutputCapping.swift), which is the single per-tool chain behind all three composition sites (root `makeSessionToolWiring`, fork, restore) — so extending `wrapping`''s non-String fallback covers every session mount at once. `ToolContext` already has the exact stamping initializer needed (`init(stamping:sessionID:mailbox:sink:completionToken:isCancelled:)`), and `ContextBindingTool<T.Arguments, T.Output>` can be constructed directly from the concrete `T` inside `wrapping`''s `open<T: Tool>` — no existential wall, so contract option 1 (binding-only wrapper) lands cleanly. Plan: RED tests first (wrapping wraps non-String tools in the binding wrapper; ambient posts carry the tool''s own name stamp + fresh per-call correlationID; route covered through makeSession(tools:)), then the wrapper, then doc updates on makeSessionToolWiring / sessionMounted / makeSession(tools:) / RoutedSession.tools / ToolElevation.wrapping. Existing pin test `factoryPassesThroughNonStringOutput` pins the superseded contract and will be replaced by the new-behavior test.'
  timestamp: 2026-08-05T06:23:18.975404+00:00
- actor: claude-code
  id: 01kz8a120en2eqbcj2hhc06v58
  text: 'Implementation landed — contract option 1 (binding-only wrapper). TDD sequence: (RED) three failing tests first — `factoryBindsNonStringOutputTool` + `nonStringOutputToolAmbientPostsCarryPerCallIdentity` (ElevatingToolTests, replacing the superseded pass-through pin `factoryPassesThroughNonStringOutput`) and the acceptance test `nonStringOutputToolAmbientRouteThroughMakeSession` (SessionOutboxToolWiringTests, composed through makeSession(tools:), asserting on session.outbox) — watched fail on the missing wrapper, then again on the missing binding ("unbound", zero events); (GREEN) added `ContextBindingTool<Arguments, Output>` in Hosting/ElevatingTool.swift and routed `ToolElevation.wrapping`''s non-String guard through it. The wrapper mints a fresh completionToken per call, stamps tool/op via `ToolContext(stamping:...)`, mirrors caller cancellation into the honest isCancelled probe via withTaskCancellationHandler + the file''s CancellationRequestFlag, and synthesizes nothing (silent run posts no events — pinned by test). Docs updated on all acceptance sites (`makeSessionToolWiring`, `sessionMounted`, `makeSession(tools:)`) plus `ToolElevation.wrapping`, `RoutedSessionActor.tools`, `turnBindingToolStamp`, ForkableTool, SessionTreeRestoration, the wiring-suite header, and the shared `elevationWrapped` peeler (now peels both layers). Shared fixtures `NonStringToolOutput`/`AmbientNonStringOutputTool` added to Helpers/AmbientEventToolFixtures.swift; the tool returns the observed ambient completionToken so tests match posted correlationIDs against each call''s own token. `ToolOutputCapping.wrapping`''s non-String pass-through pin stays — capping genuinely remains String-only. swift build clean; swift test fully green (723+20+12 tests, 0 failures).'
  timestamp: 2026-08-05T06:33:29.358064+00:00
- actor: claude-code
  id: 01kz8cpbc5qb5672pvh1yyrp8c
  text: 'Self-review + double-check completed. Self-review round 1 findings (fixed): doc comment on `NonStringToolOutput.promptRepresentation`; fork-site non-String coverage (`forkComposedNonStringOutputToolPostsToForkOutbox`). Round 2 findings (fixed): with-budget coverage for non-String tools at both sites — the pinned contract is bind-only even under a budget, since capping has no String output to truncate (`makeSessionWithBudgetComposesBindOnlyForNonStringOutput`, `forkWithBudgetComposesBindOnlyForNonStringOutput`). Round 3 clean. Double-check verdict was REVISE with 3 findings, all fixed: (1) `runCancellableModelCall`''s cancellation-boundary doc now states a ContextBindingTool call runs in-band and dies with the turn, its completionToken being correlation identity only, never mailbox-addressable; (2) six remaining single-layer "elevation layer" doc sites updated to the two-wrapper phrasing (fork() inline comments x2, LanguageModelSessionBackend.makeFork(tools:), LiveModelLoader.makeFork(tools:), OperationEventSink protocol doc, SessionOutbox turn-riding-events bullet); (3) the ambient route is now proven under a live turn-scope binding — ToolInvokingBackend generalized to invoke the binding wrapper and capture the turn token, new test `nonStringToolPerCallBindingShadowsTurnScopeBindingInsideRespond` drives a real session.respond and asserts the tool''s posts carry its own name/token, not "session"/"respond" or the turn''s token — and the restore site got its own pin (`restoredRootWrapsNonStringOutputToolInItsOwnBindingLayer`). Final: swift build clean, swift test 728+20+12 all green, review working clean.'
  timestamp: 2026-08-05T07:20:04.229899+00:00
- actor: claude-code
  id: 01kz8cpkrr8pw1vkrv12g2jjx1
  text: |-
    ### implement — changed
    - evidence: contract option 1 (binding-only `ContextBindingTool`). 15 files — Sources: Hosting/ElevatingTool.swift, Hosting/ForkableTool.swift, Hosting/OperationEventSink.swift, Recording/SessionTreeRestoration.swift, RoutedLLM.swift, Session/RoutedSession.swift, Session/ToolOutputCapping.swift, Session/LanguageModelSessionBackend.swift, Session/SessionOutbox.swift, Resolution/LiveModelLoader.swift; Tests: ElevatingToolTests.swift, SessionOutboxToolWiringTests.swift, SessionTreeRestorationToolWiringTests.swift, Helpers/AmbientEventToolFixtures.swift, Helpers/ElevationTestHelpers.swift. swift build clean; swift test 728+20+12 green, 0 failures; review working clean; double-check REVISE findings all resolved.
    - next: ready for /review
  timestamp: 2026-08-05T07:20:12.824615+00:00
- actor: claude-code
  id: 01kz8cwmqbmv85wc4h7tb0ytr7
  text: |-
    ### test — green
    - evidence: `swift test` — 3 test runs (728+20+12 = 760 tests) all passed, 0 failed, 32 skipped (gated, expected ~28-32 range); only warning is the known pre-existing llbuild "missing creator for mutated node" from mlx-swift Cmlx bundle
    - HumanWaitGateTests re-run 3x in isolation (`swift test --filter HumanWaitGateTests`) — 9/9 passed each time, no flake reproduced
    - next: ready for review
  timestamp: 2026-08-05T07:23:30.411955+00:00
- actor: claude-code
  id: 01kz8dtxe21qk1edg85ec3846r
  text: |-
    ### review — findings
    - evidence: 5 findings (review sha HEAD~1..HEAD, commit c6a3f2a) — Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:663, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:1013, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:357, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:430, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:475
    - next: implement the 5 new non-String-output composition/routing tests recorded in the 2026-08-05 02:25 Review Findings section, then re-review
  timestamp: 2026-08-05T07:40:02.370122+00:00
- actor: claude-code
  id: 01kz8dvx3fwea99c60atyvqwqg
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 15 files; contract option 1: ContextBindingTool binding-only decorator, per-call per-tool ToolContext for non-String-output tools at all three composition sites
    - test: green — swift test, 760 passed, 0 failures, 32 gated skips; HumanWaitGateTests re-verified 3x
    - commit: c6a3f2a
    - review: findings — 5 (all new regression tests): SessionOutboxToolWiringTests.swift:663, :1013; SessionTreeRestorationToolWiringTests.swift:357, :430, :475
  timestamp: 2026-08-05T07:40:34.799909+00:00
- actor: claude-code
  id: 01kz8fh1f12ggpr0hvvq51y137
  text: 'Picked back up from review — working the 5 findings of "## Review Findings (2026-08-05 02:25)". All 5 implemented as new regression tests, TDD-verified meaningful via scratch-break (temporarily reverted ToolElevation.wrapping''s non-String guard to the pre-^6htgvw2 pass-through: all new tests failed on the missing ContextBindingTool wrapper; restored the guard byte-identical — git diff Sources/ clean — and all pass again). New tests: (1) parentAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently — async let concurrent posting through parent''s and fork''s own ContextBindingTool, fresh token per call, no cross-outbox migration; (2) makeSessionWithoutBudgetComposesBindOnlyForNonStringOutput + forkWithoutBudgetComposesBindOnlyForNonStringOutput — bind-only chain pinned with no budget, mirroring the String-tool structure tests; (3) eachRestoredNodeGetsItsOwnOutboxAndBindingWrapperForNonStringOutput — multi-node restore (root+fork), each node''s own ContextBindingTool over the one shared instance, identity + per-call correlationID per node; (4) forkOfRestoredSessionComposesItsOwnBindingLayerForNonStringOutput — fork-of-restored composition, child''s own wrapper, fresh token, root outbox untouched; (5) restoreComposesBindOnlyForNonStringOutput — restore-site bind(tool) chain, no capping, same pattern as restoreComposesElevateOnly. Self-review rounds: r1 flagged the with/without-budget near-duplicates — extracted shared helpers assertMakeSessionComposesBindOnlyForNonStringOutput(budget:detail:) and assertForkComposesBindOnlyForNonStringOutput(budget:detail:), all four budget-level tests now thin wrappers; r2 flagged the undocumented @unchecked Sendable on ToolCapturingRestoreContainer — invariant documented; r3 flagged missing concurrent coverage at the restore site — added restoredRootAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently; r4 clean. swift build clean; swift test 735+20+12 green (up from 728: +7 new tests).'
  timestamp: 2026-08-05T08:09:35.969248+00:00
- actor: claude-code
  id: 01kz8gdnkasyzcrrxnpfgzgpt8
  text: 'Double-check verdict was REVISE with 2 items, both implemented: (1) the 5 "## Review Findings (2026-08-05 02:25)" entries were still unchecked — flipped all 5 to [x] via update task with tags re-supplied and the description re-verified intact (known corruption behavior did not reproduce; newlines, tags, and the trailing #phase-1 #router-first markers all preserved); (2) the `!(… is TokenCappingTool<AmbientToolArguments>)` assertion in the three bind-only structure checks cannot fail for a non-String output (TokenCappingTool wraps only Tool<Arguments, String>) — kept the assertion (finding 5 demanded mirroring restoreComposesElevateOnly''s structure-checking pattern) and amended the adjacent comment at all three sites (assertMakeSessionComposesBindOnlyForNonStringOutput, assertForkComposesBindOnlyForNonStringOutput, restoreComposesBindOnlyForNonStringOutput) to state the check is type-guaranteed and the load-bearing chain proof is `wrapped` being the original instance. Double-check also independently confirmed: Sources/ byte-identical to HEAD, no vacuous assertions (the "unbound" fallback plus token-inequality companion makes the correlationID pins real), threadedToolsByCall ordering deterministic (sequential depth-first restore recursion, no flake), the @unchecked Sendable doc accurate (single makeSession(transcript:tools:) call site), and the async let tests concurrency-safe (task-local ToolContext bindings, container reads only after awaits). A final self-review round then flagged the concurrent restore test as reinventing the outbox suite''s concurrent-isolation pattern — resolved via the finding''s documentation option: doc comment on restoredRootAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently declaring the intentional mirror and why the bodies stay separate (different per-suite composition seams). Self-review clean after fix; swift test 735+20+12 green.'
  timestamp: 2026-08-05T08:25:14.090640+00:00
- actor: claude-code
  id: 01kz8gdxjdw77wb2djsktcgsfp
  text: |-
    ### implement — changed
    - evidence: 2 files — Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift. All 5 findings of "## Review Findings (2026-08-05 02:25)" implemented and checked: 7 new tests (parentAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently; makeSessionWithoutBudgetComposesBindOnlyForNonStringOutput; forkWithoutBudgetComposesBindOnlyForNonStringOutput; eachRestoredNodeGetsItsOwnOutboxAndBindingWrapperForNonStringOutput; forkOfRestoredSessionComposesItsOwnBindingLayerForNonStringOutput; restoreComposesBindOnlyForNonStringOutput; restoredRootAndForkNonStringOutputToolsPostToTheirOwnOutboxesConcurrently) plus shared helpers assertMakeSessionComposesBindOnlyForNonStringOutput/assertForkComposesBindOnlyForNonStringOutput and the documented @unchecked Sendable invariant. All new tests scratch-break verified (fail when ToolElevation.wrapping's non-String guard reverts to pass-through); Sources/ byte-identical to HEAD. swift build clean; swift test 735+20+12 green, 0 failures; review working clean; double-check REVISE items resolved.
    - next: ready for /review
  timestamp: 2026-08-05T08:25:22.253879+00:00
- actor: claude-code
  id: 01kz8gjm3cqx1yj2hjch2aqd6c
  text: |-
    ### test — green
    - evidence: `swift test` (no FM_ROUTER_INTEGRATION_TESTS) — 735+20+12 = 767 tests passed, 0 failed; 32 gated suites/tests skipped (expected range 28-32, integration env var correctly unset); build clean except pre-existing llbuild "missing creator for mutated node" warning from mlx-swift Cmlx.bundle; HumanWaitGateTests (3 tests) passed, no flake observed this run.
    - next: none — full suite green.
  timestamp: 2026-08-05T08:27:56.396630+00:00
- actor: claude-code
  id: 01kz8gmtdnbqk5kar2r8ckwq56
  text: |-
    ### commit — changed
    - evidence: 84913d4 test(router): add regression tests for ContextBindingTool composition paths
    - next: none
  timestamp: 2026-08-05T08:29:08.405284+00:00
- actor: claude-code
  id: 01kz8gvdhxthvpzakxpqjq2h8k
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (commit 84913d4) — 0 new findings (counts: findings 0, confirmed 0, refuted 0, attempted 9, failed 0); all 5 prior items in "## Review Findings (2026-08-05 02:25)" verified checked
    - next: none — task moved to done
  timestamp: 2026-08-05T08:32:44.605131+00:00
- actor: claude-code
  id: 01kz8gxfc04zx2gevsjxff5ztk
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 2 test files (7 new ContextBindingTool composition regression tests + shared assert helpers, all scratch-break verified)
    - test: green — swift test, 767 passed, 0 failures, 32 gated skips
    - commit: 84913d4
    - review: clean — 0 new findings, all 5 prior items checked; task → done
  timestamp: 2026-08-05T08:33:52.000757+00:00
position_column: done
position_ordinal: f180
title: '[Router] Non-String-output tools bypass the elevation layer: ambient events lose per-tool identity/correlation'
---
Repo: this repo (FoundationModelsRouter). Discovered while implementing ^ew49xjj (delete `EventEmittingTool`/`connecting(_:)`).

`ToolElevation.wrapping` (and `ToolOutputCapping.wrapping`) only wrap a tool whose `Output` is `String`; any other `Output` type passes through both layers unwrapped (see `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift`'s `open(_:)` guard, pinned by `ElevatingToolTests`). Before ^ew49xjj, `instanceToolsWithElevation` also applied the `connecting(_:)` cast to **every** tool regardless of output type, so a non-String-output `EventEmittingTool` conformer had its own event route posting its own `tool`/`op`/`correlationID`. After the deletion, such a tool gets no per-call `ToolContext` binding at all; its ambient posts fall back to the session's turn-scope binding in `RoutedSessionActor` (`turnBindingToolStamp`/`turnBindingOpStamp`), which stamps `tool: "session"`, `op: "respond"`, and the turn's `completionToken` as `correlationID`. Per-tool identity and per-run correlation are silently lost for that class of tool, and no test covers the route.

## What
Decide and implement the intended contract for non-String-output tools' ambient event identity:
- Either extend the elevation layer to bind a per-call, per-tool-stamped `ToolContext` for non-String-output tools too (a binding-only wrapper that skips the pending-envelope/park machinery, which requires a `String` wire form), or
- Pin the current fallback (turn-scope `"session"`/`"respond"` stamps) as the documented contract with a test.

Decided: contract option 1 — the binding-only `ContextBindingTool` wrapper.

## Acceptance Criteria
- [x] A test covers the ambient event route of a non-String-output tool composed through `makeSession(tools:)`
- [x] The doc comments on `RoutedModel.makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)`, `ToolElevation.sessionMounted(_:sessionID:mailbox:sink:cappedToTokenLimit:)`, and `makeSession(tools:)` match the decided behavior (note: ^ew49xjj's review pass renamed `instanceToolsWithElevation` into these two helpers)

## Review Findings (2026-08-05 02:25)

- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:663` — The test `parentAndForkComposedToolsPostToTheirOwnOutboxesConcurrently` (lines 574–614) verifies that parent and fork sessions post concurrently to their own outboxes for String-output tools. An equivalent concurrent posting test is missing for non-String-output tools; the existing test `forkComposedNonStringOutputToolPostsToForkOutbox` (lines 616–663) posts sequentially. Add a test that forks a session with AmbientNonStringOutputTool and posts concurrently from both parent and child using async let, verifying that concurrent per-call binding and event routing work correctly (each call gets a fresh token, each posts to its own outbox).
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift:1013` — Composition chain structure tests verify layer stacking for String-output tools both with and without budget (e.g., `makeSessionComposesElevateCap`, `makeSessionWithoutBudgetComposesElevateOnly`). Equivalent explicit structure tests are missing for non-String-output tools without budget. For consistency and invariant verification, the composition chain should be tested at all budget levels for all tool types. Add explicit composition chain tests `makeSessionWithoutBudgetComposesBindOnlyForNonStringOutput` and `forkWithoutBudgetComposesBindOnlyForNonStringOutput` that verify bind-only composition (without capping layer) is consistently applied regardless of budget, mirroring the String-tool test structure.
- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:357` — The invariant that non-String tools are wrapped in ContextBindingTool (added in this change) should hold at every site that restores tools. The test `eachRestoredNodeGetsItsOwnOutboxAndElevationWrapper` (lines 308–357) verifies composition at multi-node restore trees, but only for String-output tools with ElevatingTool. The same test should run with non-String-output tools to verify the binding wrapper invariant holds consistently across all restored nodes. Add a test that restores a tree (root + fork) using AmbientNonStringOutputTool, verifies each restored node gets its own ContextBindingTool<AmbientToolArguments, NonStringToolOutput> wrapper, and confirms events from each node post to its own outbox with the tool's identity and per-call correlationID.
- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:430` — The test `forkOfRestoredSessionComposesItsOwnElevationLayerFromTheOriginals` (lines 390–430) exercises fork-of-restored composition with String-output tools, but no test covers fork-of-restored with non-String-output tools. The change adds non-String support to both fork and restore paths; the fork-of-restored composition (which combines both transformations) should be tested to verify the interaction is correct. Add a test after line 430 that forks a restored session created with `AmbientNonStringOutputTool`, verifies the fork's tool is wrapped in `ContextBindingTool<AmbientToolArguments, NonStringToolOutput>`, and confirms events post to the child's outbox with the tool's identity and a fresh per-call token.
- [x] `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift:475` — Restoration composition structure is tested for String-output tools (`restoreComposesElevateOnly`, lines 434–475), verifying the `elevate(tool)` chain and absence of capping. An equivalent composition structure test is missing for non-String-output tools, which should verify `bind(tool)` chain consistency with the makeSession and fork patterns. Add a test `restoreComposesBindOnlyForNonStringOutput` that verifies a restored session with a non-String-output tool receives bind-only composition (no capping, no fork layer), using the same structure-checking pattern as `restoreComposesElevateOnly`. #phase-1 #router-first