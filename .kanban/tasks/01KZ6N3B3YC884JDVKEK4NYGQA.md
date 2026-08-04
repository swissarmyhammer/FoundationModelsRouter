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
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first