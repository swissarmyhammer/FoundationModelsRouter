---
assignees:
- claude-code
depends_on:
- 01M0XGQCF19BT6PM14919C9VV4
position_column: todo
position_ordinal: '8780'
title: A background body can use the generation permit
---
## What
Today a tool body that generates on a session (the agent-tool shape) gets the turn's generation permit through `withGenerationSuspendedForToolCall` — a window that exists only while the tool call blocks in-band. A background call returns at once, so its body would contend for the permit that the open turn still holds (`Sources/FoundationModelsRouter/Session/GenerationReentry.swift`, `GenerationPermitLoan.close()` keeps a detached run out of the gate's bypass). Without a design here, an agent tool that generates from a background body stalls or deadlocks.

- [ ] State and implement the rule: what a background body does for the generation permit. The body must make progress while its parent turn is still open.
- [ ] Update `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift` (3 conformances, its fixtures raise `waitSeconds` to stay in-band — that mechanism is going away): its fixtures become declared background tools under the new rule.
- [ ] Files: `Sources/FoundationModelsRouter/Session/GenerationReentry.swift`, `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift` (the permit hand-off at the call site), `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift`.

## Acceptance Criteria
- [ ] A test proves: a declared background tool whose body calls `session.respond(...)` makes progress while the parent turn is still open — no stall, no deadlock.
- [ ] The existing generation-gate balance tests stay green.
- [ ] `swift build --build-tests` and the suite are green.

## Tests
- [ ] The new case in `Tests/FoundationModelsRouterTests/NestedGenerationReentryTests.swift`.
- [ ] Run `swift test --filter NestedGenerationReentryTests` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running #bug