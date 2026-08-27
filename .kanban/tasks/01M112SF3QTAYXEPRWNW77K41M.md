---
comments:
- actor: claude-code
  id: 01m1144q1g9ajyfmdhhq6e2csb
  text: |-
    Research: read `Hosting/ForkableTool.swift` for the "no associated types" existential-cast shape, `RoutedSessionActorTurnExecution.swift`'s two drain sites, and `RoutedSessionActorForking.swift`'s note that `tools` (mounted) differs from `originalTools` (pristine) — `ForkableTool` casts against `originalTools` specifically because `tools` holds wrapped instances.

    Key finding: every tool the session mounts is wrapped by one of four decorators (`ToolMounting.makeWrapped`): `RunToCompletionRunner`, `BackgroundToolRunner`, `ContextBindingTool`, and (when a tool-output token cap is configured) `TokenCappingTool` (`ToolOutputCapping.swift`). `RoutedSessionActor.tools` holds these wrappers, never the bare original. So a naive `tool as? any TurnBoundaryTool` cast over `tools` would never succeed for any real tool passed through the normal `makeSession(tools:)` API — the hook would be dead on arrival for its actual consumer (MultiTool's own tool). Fixed by giving each of the four decorators `TurnBoundaryTool` conformance that forwards to `wrapped` when it conforms, mirroring the existing `BackgroundToolRunner.parameterProvider` pattern (`wrapped as? any BackgroundTool`) already used in this file for the same "wrapped may or may not opt in" shape.

    Implementation:
    - `Sources/FoundationModelsRouter/Hosting/TurnBoundaryTool.swift`: new public protocol, shaped like `ForkableTool`.
    - `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`: added `notifyTurnBoundaryTools()`, called after `outbox.drainPendingEvents()` in `generate(...)` and after `outbox.drainForDispatch()` in `dispatchNextPrompt()`.
    - `Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift`, `BackgroundToolRunner.swift`, `ContextBindingTool.swift`, `Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift` (`TokenCappingTool`): each now conforms to `TurnBoundaryTool`, forwarding to `wrapped` when it conforms.

    Tests: `Tests/FoundationModelsRouterTests/TurnBoundaryToolTests.swift` — a probe tool + a call-order-recording stub backend prove one `respond()` gives one call, two turns give two calls, the call precedes the model's `respond()`, and a mixed list with a non-conforming tool calls only the conformer. Tests build a real session through `RouterTestFixtures`/`profile.standard.makeSession(tools:)`, so they exercise the real mount-wrapping path, not a bypass.

    Note: `diagnostics.check working` currently reports 9 stale "Cannot find type 'TurnBoundaryTool' in scope" errors from SourceKit-LSP. Confirmed false positive: the `code_context` index was mid-rebuild (17/286 files) at the time, and two independent clean `swift build` runs plus the full `swift test` run compiled every affected file with zero errors.
  timestamp: 2026-08-27T08:07:20.368106+00:00
- actor: claude-code
  id: 01m1144xygd2y5qe3j34cbw6by
  text: |-
    ### implement — changed
    - evidence: `swift build` succeeds (2 clean runs); `swift test --filter TurnBoundaryToolTests` — 3/3 pass; full `swift test` — 1061 tests/105 suites pass (2 pre-existing known issues, unrelated) + 83/83 in the eval-support target
    - files: Sources/FoundationModelsRouter/Hosting/TurnBoundaryTool.swift (new), Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift, Sources/FoundationModelsRouter/Hosting/BackgroundToolRunner.swift, Sources/FoundationModelsRouter/Hosting/ContextBindingTool.swift, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Tests/FoundationModelsRouterTests/TurnBoundaryToolTests.swift (new)
    - next: ready for /review
  timestamp: 2026-08-27T08:07:27.440185+00:00
position_column: doing
position_ordinal: '80'
title: Add a turn-boundary hook for mounted tools (TurnBoundaryTool)
---
## What
MultiTool (FoundationModelsMultitool, phase 4 of its eventplan.md) rebuilds its rendered `tools.*` surface when an MCP server changes its tool list. eventplan.md § "Consolidation of the siblings": "The surface never changes in place. A change means rebuild and swap. ... MultiTool swaps it in atomically at the next turn boundary — the same boundary where the outbox folds in events." Router owns that boundary. Today no mounted tool can observe it.

Add a protocol in `Sources/FoundationModelsRouter/Hosting/TurnBoundaryTool.swift`, in the shape of `ForkableTool.swift` (no associated types, so `tool as? any TurnBoundaryTool` succeeds on an `any Tool` existential):

```swift
public protocol TurnBoundaryTool: Tool {
    /// The session calls this one time at each turn boundary, after it drains the outbox and before the model call of the turn.
    func turnWillBegin() async
}
```

Call it from `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift`, in the two drain sites: `generate(...)` after `outbox.drainPendingEvents()` (line ~62) and `dispatchNextPrompt()` after `outbox.drainForDispatch()` (line ~473). Iterate the mounted tools of the session, cast each to `any TurnBoundaryTool`, and await `turnWillBegin()` in mount order. A fork gets the same call on its own tools (`ForkableTool` composition).

The hook has no arguments and no return value. It is not an event route. It is a clock tick that a tool uses to apply a change it prepared at the side.

The consumer is on the FoundationModelsMultitool board: task "Swap the Registry in MultiTool at the turn boundary" (`01M112FH3741JEQ7QN97C5E13R`).

**Implementation note (see comments for detail):** the session's mounted `tools` list is always wrapped by one of four decorators (`RunToCompletionRunner`, `BackgroundToolRunner`, `ContextBindingTool`, `TokenCappingTool`) — the bare cast the card describes would never reach a real tool through the normal `makeSession(tools:)` path. Each decorator now conforms to `TurnBoundaryTool`, forwarding to its wrapped tool when it conforms, so the hook actually reaches a tool mounted the normal way.

## Acceptance Criteria
- [x] `TurnBoundaryTool` is public in `Hosting/`, and a tool that does not conform is unchanged.
- [x] The session calls `turnWillBegin()` one time per turn, on each conforming mounted tool, after the drain and before the model call.
- [x] A turn that fails before the model call still made the hook call (the hook is at the drain, not at the response).
- [x] `swift build` succeeds.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/TurnBoundaryToolTests.swift`: a probe tool records each `turnWillBegin()` call with a counter. One `respond` gives one call. Two turns give two calls. A tool that does not conform gets no call. The call happens before the model sees the prompt (use the mock backend that records order).
- [x] `swift test --filter TurnBoundaryToolTests` passes.
- [x] Full `swift test` in Router passes.

## Workflow
- Use `/tdd` — write the probe test first, then add the protocol and the two call sites. #eventplan #multitool-phase-4