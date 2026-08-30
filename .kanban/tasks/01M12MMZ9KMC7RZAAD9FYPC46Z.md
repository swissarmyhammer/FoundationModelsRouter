---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m19b4bmbqphapeex77kjmk5t
  text: |-
    Research, before writing code.

    Discoveries that shaped the work:

    1. **A tracer has to be threaded to reach the decorators.** Every other router span opens through `RouterTracing.tracer(explicit:)` with a tracer the handle carries. The three decorators carried none, and `InstrumentationSystem.tracer` is a no-op until a host bootstraps a backend — which a unit test cannot do, because bootstrap is once per process. So the tracer is now threaded `RoutedModel.tracer` -> `makeSessionToolWiring` -> `ToolMounting.makeSessionMounted` -> `ToolMounting.makeWrapped` -> each decorator. The fork site (`RoutedSessionActorForking`) passes the parent actor's own tracer, so a fork's tool spans reach the same backend as the parent's.

    2. **Task locals DO propagate into `Tool.call`.** This was the open question the propagation-probe note in `RoutedSessionToolContextBindingTests` records. The measurement: a scripted turn calling two tools reports two tool spans whose `parentSpanID` equals the turn span's `spanID`. So the turn span really is the parent, with no explicit context plumbing.

    3. **`TokenCappingTool` sits OUTSIDE the three decorators, not inside.** `makeSessionMounted` mounts first and caps the result, so the chain the model calls is `TokenCappingTool -> RunToCompletionRunner -> tool`. Leaving the capping layer uninstrumented (as the card orders) therefore gives exactly one span for a capped tool, and the new test proves it.

    4. **`RunSettlement.terminal.outcome` is richer than a success/failure flag.** `ToolRun.inBandFacts(for:)` maps a call to `.succeeded`, `.cancelled`, `.timedOut`, `.lost` or `.failed`, so `RunToCompletionRunner` writes that outcome onto the span rather than a two-value one, and a timed-out call stays distinguishable from a failed one.

    Approach not taken: reading the tracer off an ambient binding. `ToolContext` carries the session's capabilities but no tracer, and adding one there would put an observability concern on documented tool-authoring surface. The mount seam already threads every other per-session value (identity, mailbox, sink), so the tracer goes the same way.
  timestamp: 2026-08-30T12:43:24.171882+00:00
- actor: claude-code
  id: 01m19b51grf0697xmpnp7hsbha
  text: |-
    One deviation from the letter of the Tests section, stated so the reviewer does not have to find it.

    The card says: "Assert the one-span-per-call rule for a capped tool, using the fixtures from `ToolOutputCappingTests.swift`." That suite's tools are `private` nested types (`StringOutputTool`, `NonStringOutputTool`, `FakeToolArguments`), so no other file can reach them. What IS reusable from that suite is the budget shape that turns capping on, `TokenBudget(limit:toolOutputLimit:)`, and the new test uses it over the scripted-turn fixtures the rest of the suite already drives.

    The test does not stop at counting spans. A budget that never reached the mount would make a span-count-only test pass on a session that was never capped, so the test also matches the truncation marker `[truncated:` in the answer the model read back. The cap is 1 token, small enough that a marker output is really truncated.

    One shared test helper changed: `ScriptedSessionFixture.make` takes a new `budget:` parameter, defaulting to `nil`. Every existing caller is unaffected.
  timestamp: 2026-08-30T12:43:46.584157+00:00
- actor: claude-code
  id: 01m19b5ekcrtrfafz3qvgpafr4
  text: |-
    ### implement — changed
    - evidence: 12 files. Sources: Tracing/ToolCallSpan.swift (new), Tracing/RouterTracing.swift, Hosting/ToolMounting.swift, Hosting/BackgroundToolRunner.swift, Hosting/RunToCompletionRunner.swift, Hosting/ContextBindingTool.swift, Session/ToolOutputCapping.swift, Session/RoutedSessionActorForking.swift, RoutedLLM.swift. Tests: ToolTracingTests.swift (new, 6 tests), Helpers/ScriptedSessionFixture.swift, Helpers/ScriptedMarkerTools.swift.
    - TDD: the 6 new tests were written first and all 6 failed on "0 tool spans" before any source change; all 6 pass after it.
    - `swift test`: 1116 tests in 120 suites passed, plus 83 tests in 10 suites in the evals target. 0 failures. The 2 known issues are the pre-existing `RealModelHarness` and `BoundedWait` ones.
    - `swift build`: clean. The one warning is SwiftPM's pre-existing `missing creator for mutated node` on the mlx-swift bundle, unrelated to this change.
    - `swift build --package-path IntegrationTests`: builds.
    - Vocabulary added to `RouterTracing`: `AttributeKey.toolRunKind` (`tool.run_kind`), `AttributeKey.toolOutcome` (`tool.outcome`), and the `ToolRunKind` enum (`foreground`/`background`), documented as distinct from the existing `RunKind`. The `// periphery:ignore` markers on `SpanName.tool` and `AttributeKey.toolName` are removed: both now have callers.
    - DocC links repaired for the two selectors that gained a `tracer:` parameter, in RoutedLLM.swift, RoutedSessionActorForking.swift and ScriptedMarkerTools.swift. No stale spelling of either selector is left in the tree.
    - next: /review
  timestamp: 2026-08-30T12:43:59.980090+00:00
- actor: claude-code
  id: 01m19cakqpq5a72n4z6pkjhbnv
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 0f3fc7b) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 12 files reviewed; 5 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done. No open findings.
  timestamp: 2026-08-30T13:04:17.654730+00:00
- actor: claude-code
  id: 01m19cb40kw3kszw82cmzfcf75
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 12 files; new Sources/FoundationModelsRouter/Tracing/ToolCallSpan.swift and Tests/FoundationModelsRouterTests/ToolTracingTests.swift; the tracer threaded from the model handle to each mount
    - test: green — `swift test`, 1116 tests in 120 suites + 83 tests in 10 suites, 0 failed, 0 skipped; `swift build --package-path IntegrationTests --build-tests`, 2292 steps, 0 warnings, 0 errors
    - commit: 0f3fc7b — feat(tracing): open one child span per tool call
    - review: clean — 0 findings, 7 validators, task moved to done

    Note for later cards: the plain command in this card's Tests list, `swift build --package-path IntegrationTests`, builds nothing. That package declares only test targets, so `swift build` there is a no-op and reports a false green. The command that compiles the targets is `swift build --package-path IntegrationTests --build-tests`.
  timestamp: 2026-08-30T13:04:34.323554+00:00
depends_on:
- 01M12MMJY0BHS8ABZGQKBNBP4A
- 01M1332A3W2HWNRZ24R8SDFY7A
position_column: done
position_ordinal: ffffa280
title: Open one child span for each tool call
---
## What

Wrap each tool invocation in one span, nested in the turn span.

There is no single shared `call` body to instrument. `Sources/FoundationModelsRouter/Hosting/ToolDecorator.swift` holds only a `wrapped` accessor and a `TurnBoundaryTool` default; it has no `call`. `ToolMounting.makeWrapped` (Sources/FoundationModelsRouter/Hosting/ToolMounting.swift:29-79) returns exactly one of three mutually exclusive outermost decorators. Instrument those three:

- `BackgroundToolRunner.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/BackgroundToolRunner.swift:57
- `RunToCompletionRunner.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/RunToCompletionRunner.swift:57
- `ContextBindingTool.call(arguments:)` — Sources/FoundationModelsRouter/Hosting/ContextBindingTool.swift:51

Do NOT instrument `TokenCappingTool.call(arguments:)` (Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:81). It is a pass-through layer in the same chain, and a span there would double count a capped tool.

- Span name: `FoundationModelsRouter.tool` from `RouterTracing`. Kind: `.internal`.
- Attributes: `tool.name`, `session.id`, the declared run kind (foreground or background), and the outcome.
- The parent must be the turn span; task-local context propagation gives this when the tool call runs in the turn's task. For a background run, the span covers the accept-and-launch step the model sees, not the full background run.
- A tool call that throws must record the error on the span and throw again.
- Do not put tool arguments or tool output in an attribute; the shared no-leak test from the foundation task covers this.

This task depends on the Hosting demotion task because all three decorators construct a `ToolContext` through the initializers that task demotes.

## Acceptance Criteria
- [x] A turn with two tool calls makes one turn span and two tool spans.
- [x] Each tool span has the turn span as its parent.
- [x] A tool that throws keeps its span, with the error recorded.
- [x] A background tool's span covers the launch step and sets the run kind attribute.
- [x] A tool with an output token cap configured still produces exactly one tool span, not two.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/ToolTracingTests.swift`. Use `InMemoryTracer` with `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift` and the tool mount fixtures (`ToolMountFixtures.swift`, `ScriptedMarkerTools.swift`).
- [x] Cover all three decorators: a foreground `String` tool, a background tool, and a non-`String`-output tool.
- [x] Assert the one-span-per-call rule for a capped tool, using the fixtures from `ToolOutputCappingTests.swift`.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router