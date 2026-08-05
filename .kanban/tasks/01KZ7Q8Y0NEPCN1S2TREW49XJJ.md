---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7zdzmnz2ffe27v7dbzp0t1
  text: |-
    Research done. Verified all deletion sites: the only two `connecting(` call sites are RoutedLLM.instanceToolsWithElevation (root+restore chain) and RoutedSessionActor.fork's childTools map. Key discoveries:

    - ElevatingTool.call already binds ToolContext (sink = session outbox via RunEventFunnel) around every wrapped call — so the ambient event route is already live; deleting the connect step removes a redundant second route. RunEventFunnel semantics: a tool-posted `.completed` is forwarded upstream and suppresses the synthesized terminal (exactly one event lands in the outbox per posting call) — deterministic for outbox assertions after an in-band call.
    - EventEmittingToolTests.swift also holds OperationEvent Codable wire-shape tests (round trip, lowercase kind, `outcome` decodeIfPresent back-compat) that must survive — OperationEvent stays. Plan: move them to a new OperationEventTests.swift, delete the rest of the file.
    - Test rework strategy: replace sink-bound FakeEmittingTool/ForkableEmittingTool/EmittingStringTool fixtures with shared ambient-posting fixtures (post via ToolContext.current inside call) in Tests Helpers; composition assertions flip from "distinct sink-bound copy" to "original instance passes through, wrapped in the session's own ElevatingTool; calling the composed wrapper routes the event to that session's own outbox". Chain names: elevate → cap (root), fork → elevate → cap (fork), elevate (restore).
    - Extra stale prose beyond the card's list: "fork-then-connect"/"connect → elevate"/"sink-bound"/"auto-connect" phrases in RoutedLLM, RoutedSession, SessionTreeRestoration, LiveModelLoader (3 spots), plus plan.md's Hosting vocabulary line — all updated as part of the deletion.
    - TDD note: a pure protocol deletion cannot be forced red by a test (non-conforming tools already pass the cast unchanged, so the reworked identity assertions pass both before and after). Per dispatch instruction, deletion is verified by grep + green suite; the reworked tests pin the surviving contracts.
  timestamp: 2026-08-05T03:28:18.581436+00:00
- actor: claude-code
  id: 01kz800f0nptay619kw73vt6kk
  text: |-
    Implementation landed. Deleted Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift and both conformance-cast wiring sites (RoutedLLM.instanceToolsWithElevation, RoutedSessionActor.fork childTools map); updated all doc prose (chains renamed elevate → cap / fork → elevate → cap / elevate; "fork-then-connect" → "fork-then-elevate"; "sink-bound"/"auto-connect" wording removed) across RoutedLLM, RoutedSession, SessionTreeRestoration, ForkableTool, OperationEventSink, SessionOutbox, ToolOutputCapping, LanguageModelSessionBackend, LiveModelLoader, PropagationProbeIntegrationTests, plan.md.

    Tests: EventEmittingToolTests.swift deleted; its OperationEvent Codable wire-shape tests preserved in new OperationEventTests.swift. New shared fixtures Helpers/AmbientEventToolFixtures.swift (AmbientEventPostingTool, ForkableAmbientTool — post via ToolContext.current). SessionOutboxToolWiringTests + SessionTreeRestorationToolWiringTests + ToolOutputCappingTests reworked: composition assertions now pin "original instance passes through inside the session's own ElevatingTool; calling the composed wrapper routes the event to that session's own outbox" (parent/fork isolation, restore per-node isolation, cap-outermost all still behaviorally verified through the ambient route).

    Verification: grep for `EventEmittingTool|connecting(` over the whole repo returns nothing; `swift test` green — 720 tests (unit) + 20 (integration target, gated suites compile+skip) + 12 (evals), zero failures; only warning is the pre-existing SwiftPM mlx-bundle note.
  timestamp: 2026-08-05T03:38:24.149150+00:00
- actor: claude-code
  id: 01kz80vzzbsdcn3d6x8zbcpvbz
  text: |-
    Correction to the previous verification comment (double-check Finding 2): the grep claim was overstated. Verified scope: grep for `EventEmittingTool|connecting(` over `Sources/` and `Tests/` returns nothing — the task's acceptance criterion. Remaining repo-wide hits are confined to the vendored `FoundationModelsOperationTool` checkout under `.build/`, which still defines the protocol but is not a dependency of this package (Package.swift lists only mlx-swift-lm/ULID/HuggingFace/Transformers, and nothing imports it).

    Double-check Finding 1 addressed: the rewritten doc prose claimed "every tool" is wrapped in the elevation layer, but `ToolElevation.wrapping`/`ToolOutputCapping.wrapping` only wrap String-output tools — reworded all five sites (RoutedLLM makeSession tools: param + instancing comment + instanceToolsWithElevation doc, RoutedSession.tools doc, SessionTreeRestoration tools: param, ForkableTool composition-order doc) to state the String-output condition and the turn-scope ToolContext fallback for non-String-output tools. The pre-existing identity/correlation gap that fallback creates (per-tool `tool`/`op`/`correlationID` stamps lost for non-String-output tools, no test coverage) is filed as a follow-up task on this board.
  timestamp: 2026-08-05T03:53:26.251435+00:00
- actor: claude-code
  id: 01kz81g24bgwf059yyx0sqxmwn
  text: |-
    ### implement — changed
    - evidence: deleted Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift + Tests/FoundationModelsRouterTests/EventEmittingToolTests.swift; edited Sources/FoundationModelsRouter/RoutedLLM.swift, Session/RoutedSession.swift, Session/SessionOutbox.swift, Session/ToolOutputCapping.swift, Session/LanguageModelSessionBackend.swift, Recording/SessionTreeRestoration.swift, Hosting/ForkableTool.swift, Hosting/OperationEventSink.swift, Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, SessionTreeRestorationToolWiringTests.swift, ToolOutputCappingTests.swift, Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift, plan.md; added Tests/FoundationModelsRouterTests/OperationEventTests.swift + Helpers/AmbientEventToolFixtures.swift. Verified: grep `EventEmittingTool|connecting(` over Sources/+Tests/ → 0 hits; `swift test` → 720+20+12 tests passed, 0 failures; `review working` → 0 findings (twice); double-check findings implemented (String-output prose correction, follow-up task ^6htgvw2 filed, grep-scope comment corrected).
    - next: ready for /review
  timestamp: 2026-08-05T04:04:23.819167+00:00
position_column: doing
position_ordinal: '80'
title: '[Router] Delete EventEmittingTool/connecting(_:) and the conformance-cast wiring (propagation probe verdict: context propagates)'
---
Repo: this repo (FoundationModelsRouter). Basis: task ^c25mpnw's propagation probe verdict (PropagationProbeIntegrationTests, real run 2026-08-04): the @TaskLocal ToolContext bound around respond() DOES arrive inside call(arguments:) on both the MLX path and the system model, carrying the exact bound completionToken. Per eventplan.md §"Phases" phase 1 and §"The ambient context" effect 3, the propagates-branch deletes the protocol: native tools get the ambient context free, so composition-time event wiring is redundant.

## What
Delete the `EventEmittingTool` protocol and every conformance-cast wiring site, leaving the ambient `ToolContext` (bound per call by `ElevatingTool`, and by `RoutedSessionActor` around backend calls) as the one event route.

Code deletion sites (verified by grep — the only two `connecting(` call sites in Sources/):
- `Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift` — the whole file.
- `Sources/FoundationModelsRouter/RoutedLLM.swift` — the `(tool as? any EventEmittingTool)?.connecting(outbox) ?? tool` step in the per-session tool composition (and the doc comments describing "implementing the protocol IS the subscription").
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift` — the fork path's `(forked as? any EventEmittingTool)?.connecting(childOutbox) ?? forked` step and the `connecting(_:)`-centric doc comments on `tools`/fork composition.

Doc-comment-only references to update (no `connecting(` call sites; prose only):
- `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` (restoration goes through the shared `instanceToolsWithElevation` helper; its doc comments describe the per-node `connecting(_:)` copy)
- `Sources/FoundationModelsRouter/Hosting/ForkableTool.swift` (composition-order contract)
- `Sources/FoundationModelsRouter/Hosting/OperationEventSink.swift`
- `Sources/FoundationModelsRouter/Session/SessionOutbox.swift`
- `Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift`
- `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`

Tests to delete/rework (every test file declaring an `EventEmittingTool` conformance or composing through `connecting(_:)`):
- `Tests/FoundationModelsRouterTests/EventEmittingToolTests.swift` — delete/rework wholesale.
- `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift` — its `FakeEmittingTool` conformance and the composition-order suites built on it.
- `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift` — its emitting-tool conformance.
- `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift` — `cappingComposesWithEventEmittingTool` and any other `connecting(_:)` composition.
- Sweep the remaining `EventEmittingTool` grep hits in Tests/ after these — the protocol must not survive anywhere.

Keep `OperationEventSink` and `SessionOutbox`'s sink conformance — the ambient `ToolContext` still posts through a sink; only the tool-side discovery protocol and its cast wiring go away.

## Acceptance Criteria
- [ ] `EventEmittingTool` and `connecting(_:)` no longer exist anywhere in Sources/ or Tests/
- [ ] Session/fork/restoration tool composition still wires elevation (`ToolElevation.wrapping`) and capping, with events flowing through the ambient `ToolContext` only
- [ ] `swift test` (ungated) green; gated suites still compile

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first