---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1s9tb6tn86gpqdxqkqgkna1
  text: |-
    ### research

    - The six dependency cards are done on branch `pool`. `ModelPool` (`Sources/FoundationModelsRouter/Resolution/ModelPool.swift`) has `shared`, `init()`, `residentModelCount`, and `withResolveLock`. `Router.init` has `samplingMode:` and `pool: ModelPool = .shared`. `Router.pool` is `package nonisolated let`, so a test compares it with `===`.
    - `PooledResidencyTests.defaultPoolIsShared` already pins that a router with no `pool:` argument uses `ModelPool.shared`. The new suite does not repeat it.
    - `RealModelHarnessTests` compares `samplingMode == .greedy`, so the type is comparable.
    - `CIWorkflowTests` and `UpstreamAsksDocumentTests` each computed the repository root from `#filePath`. A third copy would be a duplication, so the root moved to one helper, `Tests/FoundationModelsRouterTests/Helpers/RepositoryRoot.swift`, and both suites use it.
    - No formatter config (`.swiftformat`, `.swift-format`, `.swiftlint.yml`) is in the repository root. No DocC plugin is in `Package.swift`, so the DocC criterion does not apply.
    - TDD: `ReadmeSymbolsTests.readmeSectionNamesEveryPinnedSymbol` was red first (README had no "## Residency is process-wide" heading) and went green after the README edit. The three symbol tests pin behavior that already exists, as the card asks, so they passed on the first run.
    - The `warning: missing creator for mutated node ... mlx-swift_Cmlx.bundle` line in each `swift test` run is a SwiftPM build-system note about a dependency bundle. It is present before this change.
  timestamp: 2026-09-05T17:28:18.394014+00:00
- actor: claude-code
  id: 01m1sa055xqcw6rg9vt1dz3d1g
  text: |-
    ### implement — changed
    - evidence: 9 files — README.md, model-pool.md, Sources/FoundationModelsRouter/Resolution/ModelPool.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, Tests/FoundationModelsRouterTests/ReadmeSymbolsTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/RepositoryRoot.swift (new), Tests/FoundationModelsRouterTests/Helpers/MarkdownSection.swift (new), Tests/FoundationModelsRouterTests/CIWorkflowTests.swift and Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift (both now call the two new helpers)
    - tests: `swift test --filter 'ReadmeSymbolsTests|CIWorkflowTests|UpstreamAsksDocumentTests'` → 9 tests in 3 suites passed; full `swift test` → 1235 tests in 134 suites passed (2 known issues, present before) plus 83 tests in 10 suites passed; zero failures; the only `warning:` line is the SwiftPM `mlx-swift_Cmlx.bundle` note, present before this change
    - next: /test, then /commit, then /review
  timestamp: 2026-09-05T17:31:28.829585+00:00
- actor: claude-code
  id: 01m1sa2188z24ms74pwbw0xbqq
  text: |-
    ### test — green
    - evidence: `swift test` — 1235 tests in 134 suites passed (2 known issues: `withKnownIssue` blocks at RealModelHarness.swift:72 and BoundedWait.swift:114, present before this card) plus 83 tests in 10 suites passed; 0 failures, 0 skipped. `swift build --package-path IntegrationTests --build-tests` — exit 0. The only `warning:` lines are SwiftPM's `missing creator for mutated node ... mlx-swift_Cmlx.bundle` note for the root and nested packages, emitted by the build system for a dependency bundle and present before this card; no compiler warning in any source file.
    - next: /commit
  timestamp: 2026-09-05T17:32:30.344468+00:00
- actor: claude-code
  id: 01m1sa344bya04ajk37wmddwd8
  text: |-
    ### commit — changed
    - evidence: 6606f54 docs(pool): state that residency is process-wide in the README and the doc comments (local commit on branch `pool`, no push)
    - next: /review 01M1RRGVGRRP1AMFPRDEV2MK48 HEAD~1..HEAD
  timestamp: 2026-09-05T17:33:06.059812+00:00
- actor: claude-code
  id: 01m1sa894j3ty8cd2vqnh32e1z
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 6606f54) — 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed, 0 skipped. 8 files reviewed. Not reviewed: `.kanban/` (2 files, `.reviewignore`), `README.md` and `model-pool.md` (no validator matches Markdown). No prior `## Review Findings` section is on the card.
    - next: move to done
  timestamp: 2026-09-05T17:35:55.026076+00:00
- actor: claude-code
  id: 01m1sa8dnt1xjdy2m53awtr4wq
  text: |-
    ### finish iteration 1 — review clean, card moves to done
    - implement: changed — README.md, model-pool.md, Sources/FoundationModelsRouter/Resolution/ModelPool.swift, Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift, Tests/FoundationModelsRouterTests/ReadmeSymbolsTests.swift, Tests/FoundationModelsRouterTests/Helpers/RepositoryRoot.swift, Tests/FoundationModelsRouterTests/Helpers/MarkdownSection.swift, Tests/FoundationModelsRouterTests/CIWorkflowTests.swift, Tests/FoundationModelsRouterTests/UpstreamAsksDocumentTests.swift
    - test: green — `swift test` 1235 tests in 134 suites passed (2 pre-existing known issues) + 83 tests in 10 suites passed, 0 failures, 0 skipped; `swift build --package-path IntegrationTests --build-tests` exit 0
    - commit: 6606f54
    - review: clean — 0 findings, 0 failed tasks
  timestamp: 2026-09-05T17:35:59.674716+00:00
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
- 01M1RRFNF0JT50QDZHCRB2XNXC
- 01M1RRG1E1EVTDZVRQ919T04M2
- 01M1RS3MJ88F1NEKZCCQABTHG8
position_column: done
position_ordinal: ffffcb80
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
- [x] `README.md` has the new section and every code symbol it names exists in `Sources/`.
- [x] `ModelPool`, `Router`, and `ResidentModelGates` doc comments state the rules above.
- [x] `swift build` and `swift test` are green; DocC (`swift package generate-documentation`, if the project runs it) reports no broken symbol links. (The project has no DocC plugin, so no DocC run applies.)

## Tests
- [x] New `Tests/FoundationModelsRouterTests/ReadmeSymbolsTests.swift`: each backtick symbol in the new README section (`ModelPool.shared`, `ModelPool.residentModelCount`, `Router(pool:)`, `Router(samplingMode:)`) is referenced at compile time in the test, so a rename breaks the test.
- [x] Run `swift test --filter ReadmeSymbolsTests` → passes.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #docs