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
position_column: doing
position_ordinal: '80'
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
- [x] The doc comments on `RoutedModel.makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)`, `ToolElevation.sessionMounted(_:sessionID:mailbox:sink:cappedToTokenLimit:)`, and `makeSession(tools:)` match the decided behavior (note: ^ew49xjj's review pass renamed `instanceToolsWithElevation` into these two helpers) #phase-1 #router-first