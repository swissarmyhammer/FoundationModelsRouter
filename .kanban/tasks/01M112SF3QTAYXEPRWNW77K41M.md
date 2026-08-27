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
- actor: claude-code
  id: 01m116t2seezv328fgh2pw4cte
  text: |-
    ### review — findings
    - evidence: 2 findings (2 confirmed, 2 refuted) on `review sha HEAD~1..HEAD` — Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:80, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:92
    - next: remove the duplicated `turnWillBegin()` forwarding from all four decorators — put one shared default in place of the copies. Then run the review again.
  timestamp: 2026-08-27T08:53:57.678298+00:00
- actor: claude-code
  id: 01m116tewpxj3se10kyan992w1
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files (TurnBoundaryTool.swift new, TurnBoundaryToolTests.swift new, two call sites, four wrapper conformances)
    - test: green — swift test, EXIT=0, 1061 tests in 105 suites + 83 tests in 10 suites, 0 failures
    - commit: de26d62
    - review: findings — Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:80, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:92
    - next: implement, to work the unchecked Review Findings items
  timestamp: 2026-08-27T08:54:10.070007+00:00
- actor: claude-code
  id: 01m1175hark8qmd4nzjgzy021x
  text: |-
    Both duplication findings are answered by one shared default, not by an edit of the two named lines.

    New file `Sources/FoundationModelsRouter/Hosting/ToolDecorator.swift` holds an internal `ToolDecorator` protocol with one requirement, `var wrapped: Wrapped { get }`, over an unconstrained `associatedtype Wrapped`. The associated type is what makes one protocol fit all four decorators: three of them store `any Tool<Arguments, String>` and `ContextBindingTool` stores `any Tool<Arguments, Output>`. A property witness cannot widen its type in Swift, so a requirement written as `var wrapped: any Tool { get }` would have forced a per-decorator computed accessor — that is, the same copy in a new place. The associated type lets each existing stored `let wrapped` satisfy the requirement as it stands, with no added member.

    The one body now lives in `extension TurnBoundaryTool where Self: ToolDecorator`. It is the witness for the protocol requirement, so a call through an `any TurnBoundaryTool` existential still dispatches to it.

    `RunToCompletionRunner`, `BackgroundToolRunner`, `ContextBindingTool` and `TokenCappingTool` each add `ToolDecorator` to the conformance list and lose their `turnWillBegin()` body and its doc comment. `grep turnWillBegin Sources/` now answers 3 sites: the protocol requirement, the shared default, and the session's call site.

    Access control: `ToolDecorator` is internal, since every conformer is internal and no other module names it. The constrained extension of the public `TurnBoundaryTool` is internal for the same reason, which the compiler accepts because each conformance is internal too.

    Declarations of three of the decorators go over the line width with the added conformance, so they take the wrapped-generic-clause shape `ContextBindingTool` already used in this same family of files. No formatter was run.

    Evidence: `swift build` clean; `swift test --filter TurnBoundaryToolTests` 3/3 pass; full `swift test` 1061 tests in 105 suites pass with the 2 pre-existing known issues (RealModelHarness embedding slot, BoundedWait), plus 83 tests in 10 suites in the eval-support target. EXIT=0.
  timestamp: 2026-08-27T09:00:13.016077+00:00
- actor: claude-code
  id: 01m1175p3j1zp6p90803zyy0k6
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Hosting/ToolDecorator.swift (new), Hosting/RunToCompletionRunner.swift, Hosting/BackgroundToolRunner.swift, Hosting/ContextBindingTool.swift, Session/ToolOutputCapping.swift. Both Review Findings items are checked. `swift build` clean; `swift test` 1061 tests/105 suites + 83 tests/10 suites, EXIT=0, 2 pre-existing known issues.
    - next: ready for /review
  timestamp: 2026-08-27T09:00:17.906073+00:00
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

**Implementation note (see comments for detail):** the session's mounted `tools` list is always wrapped by one of four decorators (`RunToCompletionRunner`, `BackgroundToolRunner`, `ContextBindingTool`, `TokenCappingTool`) — the bare cast the card describes would never reach a real tool through the normal `makeSession(tools:)` path. Each decorator conforms to `TurnBoundaryTool` through the shared `ToolDecorator` protocol, whose one default forwards to the wrapped tool when it conforms, so the hook actually reaches a tool mounted the normal way.

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

## Review Findings (2026-08-27 03:49)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:80` `duplication/duplication` — Verbatim copy of `turnWillBegin()` implementation found in four decorator types (BackgroundToolRunner, ContextBindingTool, TokenCappingTool). Identical one-liner forwarding to wrapped tool should be extracted to a shared protocol extension or helper to prevent drift and reduce maintenance surface. Extract `turnWillBegin()` into a shared protocol extension default implementation on a common `ToolDecorator` protocol or helper, or use a protocol extension on `TurnBoundaryTool` if the protocol can be extended to require a `wrapped` property accessor.
- [x] `Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:92` `duplication/duplication` — Verbatim copy of `turnWillBegin()` implementation found in four decorator types (BackgroundToolRunner, ContextBindingTool, RunToCompletionRunner). Identical one-liner forwarding to wrapped tool should be extracted to a shared protocol extension or helper to prevent drift and reduce maintenance surface. Extract `turnWillBegin()` into a shared protocol extension default implementation on a common `ToolDecorator` protocol or helper, or use a protocol extension on `TurnBoundaryTool` if the protocol can be extended to require a `wrapped` property accessor.
