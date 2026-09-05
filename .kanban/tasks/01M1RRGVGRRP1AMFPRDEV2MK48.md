---
assignees:
- claude-code
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
- 01M1RRFNF0JT50QDZHCRB2XNXC
- 01M1RRG1E1EVTDZVRQ919T04M2
- 01M1RS3MJ88F1NEKZCCQABTHG8
position_column: todo
position_ordinal: '8680'
title: Document process-wide residency in README, ModelPool, and Router doc comments
---
Plan: `model-pool.md` §2, §2.7, §5.

## What
Make the process-wide pool visible to a reader who never opens `model-pool.md`.

- `README.md`: after the `await profile.release()` example (line 59 area), add a short section "Residency is process-wide": one pool per process by default (`ModelPool.shared`); a model two routers name is loaded one time and priced one time; a model is evicted only when no profile in the process holds it, so a dropped `Router` frees nothing and a host can read `ModelPool.residentModelCount`; `Router(pool:)` for an isolated pool; `Router(samplingMode:)` for the decoding strategy; the fork ceiling of a shared model comes from the router that loaded it. Keep it under twenty lines. Write it in ASD-STE100 Simplified Technical English.
- `Sources/FoundationModelsRouter/Resolution/ModelPool.swift`: the type doc comment states the sharing rule, the first-loader-wins rule, the lock scope (resolves serialize process-wide), the lifetime rule (a container is freed only by `release`), and the test isolation rule (every test router names a pool).
- `Sources/FoundationModelsRouter/Router.swift`: the type doc comment paragraph that starts "A router admits several resident profiles" says the pool is shared across routers and points to `ModelPool`.
- `Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift`: the doc comment says the gate set is per pool entry, every router over one container contends on one generation gate, and the fork ceiling is the loading router's `maxConcurrentForks`.
- `model-pool.md`: mark §1 as the state before the change.

## Acceptance Criteria
- [ ] `README.md` has the new section and every code symbol it names exists in `Sources/`.
- [ ] `ModelPool`, `Router`, and `ResidentModelGates` doc comments state the rules above.
- [ ] `swift build` and `swift test` are green; DocC (`swift package generate-documentation`, if the project runs it) reports no broken symbol links.

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/ReadmeSymbolsTests.swift`: each backtick symbol in the new README section (`ModelPool.shared`, `ModelPool.residentModelCount`, `Router(pool:)`, `Router(samplingMode:)`) is referenced at compile time in the test, so a rename breaks the test.
- [ ] Run `swift test --filter ReadmeSymbolsTests` → passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #docs