---
assignees:
- claude-code
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
- 01M1RS3MJ88F1NEKZCCQABTHG8
position_column: todo
position_ordinal: '8580'
title: 'Gated: two live routers over one pool load a real model one time'
---
Plan: `model-pool.md` §3.

## What
Add `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift`, a real-model suite in the nested package. Follow the shape of the existing gated suites there (see `IntegrationTests.swift` around the `Router(` construction and `MetalLibraryTestBootstrap`) and the profile the gated suites already load (Muse Glimmer), so no new download is needed.

- Build two `Router`s over `LiveModelLoader` with one explicit `ModelPool()`, so the test does not touch `ModelPool.shared`.
- Bind `InMemoryTracing` (the `swift-distributed-tracing` product the root tests already link; see `Tests/FoundationModelsRouterTests/ResolveTracingTests.swift` for the setup) and count `load` spans (`RouterTracing.SpanName.load`).
- Resolve the same profile from each router. Make a session from each router and send one prompt.
- Release the first profile, then send a prompt through the second router's session. Then release the second profile.

## Acceptance Criteria
- [ ] The first resolve opens one `load` span per distinct ref; the second resolve opens zero `load` spans.
- [ ] Both sessions return a non-empty answer.
- [ ] After the first router's profile is released, the second router's session still answers, with zero new `load` spans.
- [ ] `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` → all pass.

## Tests
- [ ] `secondRouterOpensNoLoadSpans`
- [ ] `releaseFromTheFirstRouterKeepsTheSecondRouterAlive`
- [ ] Run `swift test --package-path IntegrationTests` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #integration #real-model