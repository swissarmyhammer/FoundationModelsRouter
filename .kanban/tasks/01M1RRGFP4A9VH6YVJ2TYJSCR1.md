---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1s7ygwqdew3h9cc33csfeqr
  text: |-
    ### research — what the suite is built on
    - `Router.acquireModel` (Router.swift:381) opens the `load` span only inside the pool's `load` closure. The pool runs that closure only for a key it does not hold. So a second router that finds the key resident opens zero `load` spans. The tracer proves the share.
    - The residency key is `(ModelRef, role)` with no context. `RealModels.standard` and `RealModels.flash` name one repo, so a resolve loads two keys: one generation model and one embedder. The suite reads the expected count off the resolved profile's distinct refs, not off a constant.
    - `Router.init` has `tracer:`, `samplingMode:` and `pool:`. `LiveModelLoader.init(downloader:tokenizerLoader:weightsLocation:)` has no sampling mode. `RealModelContainer.load` builds the loader with no `weightsLocation`, so the suite does the same.
    - Each router gets its own `LiveModelLoader` and its own `InMemoryTracer`. Two tracers give a direct count for each router. Two loaders show that the second router's loader is never used.
    - The nested package does not link `InMemoryTracing`. `IntegrationTests/Package.resolved` already pins `swift-distributed-tracing` (through the root package), so the manifest needs one `.package` entry and one product on the integration test target, with no new resolution.
    - Every gated suite makes its temp directories from `FileManager.default.temporaryDirectory` with the suite name and a UUID. The suite follows that.
    - The chat template date pin (`PinnedDateTokenizerLoader`) exists for exact-text assertions. This suite asserts only non-empty answers and span counts, so it does not pin the date.
    - No `.swiftformat`, `.swift-format` or `.swiftlint.yml` file is in the repo root, and `ci.yml` runs no formatter.
  timestamp: 2026-09-05T16:55:38.135439+00:00
- actor: claude-code
  id: 01m1s8ay7g4va2y8ycc4e5tdx7
  text: |-
    ### implement — changed
    - evidence: 4 files — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift (new suite, two tests), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedRealProfile.swift (new: `gatedRealProfile` and `gatedRealProfileResidentContainerCount`, hoisted out of `IntegrationTests.swift` so the new suite does not copy the definition), IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift (reads the shared definition), IntegrationTests/Package.swift (pins `swift-distributed-tracing` and links `InMemoryTracing` to the integration test target)
    - `swift build --package-path IntegrationTests --build-tests` → exit 0
    - next: test step — root `swift test`, then the filtered gated run, then the full gated run
  timestamp: 2026-09-05T17:02:25.008382+00:00
- actor: claude-code
  id: 01m1s96smq0kmrdnjc9b91p684
  text: |-
    ### test — green
    - evidence: root `swift test` → 1231 tests in 133 suites passed (2 known issues, both pre-existing `withKnownIssue` marks) and 83 tests in 10 suites passed, exit 0; `swift build --package-path IntegrationTests --build-tests` → exit 0; `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` → 2 tests in 1 suite passed (47.2 s and 25.9 s), exit 0; `swift test --package-path IntegrationTests` → 36 tests in 18 suites passed and 2 tests in 2 suites passed, exit 0, 12.6 minutes; the new tests measured 46.3 s and 26.0 s inside the full run
    - warnings: none from source. The one `warning: missing creator for mutated node (... mlx-swift_Cmlx.bundle ...)` line is the build system's, and the root `swift test` prints the same line, so it predates this change
    - next: commit
  timestamp: 2026-09-05T17:17:37.815646+00:00
- actor: claude-code
  id: 01m1s97rnpgknn95pqdtqmm2ne
  text: |-
    ### commit — changed
    - evidence: 69fb0f6 test(pool): prove two live routers over one pool load a real model one time — 6 files, 370 insertions, 57 deletions, local only
    - next: review HEAD~1..HEAD
  timestamp: 2026-09-05T17:18:09.590775+00:00
- actor: claude-code
  id: 01m1s9cx7zqnn20thj6e36pwhh
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` → 0 findings, 7 validator tasks attempted, 0 failed, 0 skipped; 4 files reviewed, 2 `.kanban/` files excluded by `.reviewignore`; no prior `## Review Findings` section on the card
    - next: move to done
  timestamp: 2026-09-05T17:20:58.111692+00:00
- actor: claude-code
  id: 01m1s9d6k47zf1736ertceg87n
  text: |-
    ### finish iteration 1 — review clean, card moved to done
    - implement: changed — IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/CrossRouterPoolIntegrationTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/GatedRealProfile.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift, IntegrationTests/Package.swift
    - test: green — root `swift test` 1231 tests in 133 suites + 83 tests in 10 suites passed; `swift build --package-path IntegrationTests --build-tests` exit 0; `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` 2 tests in 1 suite passed (47.2 s, 25.9 s); `swift test --package-path IntegrationTests` 36 tests in 18 suites + 2 tests in 2 suites passed in 12.6 minutes; zero failures, zero source warnings
    - commit: 69fb0f6
    - review: clean — 0 findings, 7 attempted, 0 failed
  timestamp: 2026-09-05T17:21:07.684158+00:00
depends_on:
- 01M1RREG728QK5FMX6N8H2G4SB
- 01M1RRF9KB8W919YZ27A4721B3
- 01M1RS3MJ88F1NEKZCCQABTHG8
position_column: done
position_ordinal: ffffca80
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
- [x] The first resolve opens one `load` span per distinct ref; the second resolve opens zero `load` spans.
- [x] Both sessions return a non-empty answer.
- [x] After the first router's profile is released, the second router's session still answers, with zero new `load` spans.
- [x] `swift test --package-path IntegrationTests --filter CrossRouterPoolIntegrationTests` → all pass.

## Tests
- [x] `secondRouterOpensNoLoadSpans`
- [x] `releaseFromTheFirstRouterKeepsTheSecondRouterAlive`
- [x] Run `swift test --package-path IntegrationTests` → all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #model-pool #integration #real-model