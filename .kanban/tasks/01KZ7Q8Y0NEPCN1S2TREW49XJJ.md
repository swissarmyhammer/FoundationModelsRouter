---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
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