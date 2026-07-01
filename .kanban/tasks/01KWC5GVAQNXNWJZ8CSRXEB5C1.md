---
comments:
- actor: wballard
  id: 01kwdgpyb64gmh6p5bpw4n0dh9
  text: 'Picked up. Read RoutedLLM/RoutedEmbedder (RoutedModel<Container> final class - reference identity works with ===), LanguageModelProfile, RoutedSession, and the stub-loader/InMemoryRecorder patterns in ResolveTests/SessionChokepointTests/ProfileLifecycleTests. Plan: add SummarizeTool(model: RoutedLLM) + EmbedTool(model: RoutedEmbedder) in Sources/, plus ToolIntegrationTests with a load-counting loader spy. TDD: writing failing tests first.'
  timestamp: 2026-07-01T00:19:24.646332+00:00
- actor: wballard
  id: 01kwdh0erbknffvvzcf73gg630
  text: |-
    Done (TDD, GREEN). Added Sources/FoundationModelsRouter/Tools.swift with SummarizeTool(model: RoutedLLM) (summarize -> makeSession(instructions:).respond) and EmbedTool(model: RoutedEmbedder) (embed/dimension -> model.embed), plus a module doc comment documenting the shared-handle constructor pattern (pass slot handle in; do not re-resolve per tool). Cross-referenced the pattern from the RoutedLLM/RoutedEmbedder typealias docs in LanguageModelProfile.swift. Added Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift with a load-counting LoaderSpy + canned containers + InMemoryRecorder: (1) two tools from profile.flash share one resident model via === identity and the loader's flash-slot load count stays 1 (no reload on construction); (2) a summarize call records [.prompt,.response] and an embed call records one .embedding event through the handle's recorder with correct provenance; (3) constructing tools leaves one-active-profile residency intact (second resolve throws RouterError; resolve succeeds after release).

    Verification (DEVELOPER_DIR=Xcode-beta): `swift test --filter ToolIntegrationTests` -> 4/4 pass. Full `swift test` -> 84 tests + 1, all pass, no new warnings. Adversarial double-check verdict: PASS. Left in doing for /review.
  timestamp: 2026-07-01T00:24:36.363864+00:00
- actor: wballard
  id: 01kwdhptbvbt7ptsw9gf8wpp8k
  text: |-
    Reworked review findings (pulled review→doing). Acronym-casing findings in Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift:

    1. recordLLMLoad (:65) — case (a) test-only spy method. Renamed to recordLlmLoad; also fixed its sole call site in StubModelLoader.loadLLM.
    2. totalRAM (:80) — case (b) BLOCKED. StubProbe.totalRAM satisfies the MachineProbe protocol requirement `var totalRAM: Int64 { get }` (milestone 1, Sizing/HostProfile.swift). No test-local var exists to rename; the property name is the conformance and the memberwise-init label derives from it. Cannot rename without a project-wide production acronym-rename of the accepted MachineProbe API — out of scope for milestone 6. Left unchanged, finding left unchecked, reported to user.
    3. configJSON (:127) — case (b) test-local static let. Renamed to configJson; kept production label RawRepoMetadata(configJSON:) at call site.
    4. treeJSON (:137) — case (b) test-local static let. Renamed to treeJson; kept production label RawRepoMetadata(treeJSON:) at call site.

    No production/milestone-1/3 code touched. Verified GREEN with DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer: `swift test --filter ToolIntegrationTests` → 4/4 pass; full `swift test` → 84 tests pass (+1 gated integration test skipped as designed). Task left in doing for review.
  timestamp: 2026-07-01T00:36:49.147043+00:00
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
position_column: doing
position_ordinal: '80'
title: 'Tool integration: shared-profile constructor pattern (milestone 6)'
---
## What
Validate the plan's core "built early and shared" goal: tools take the router (or a model it vends) in their constructors so many tools reuse a small set of resident models. Plan "Goal" + milestone 6.

- `Sources/FoundationModelsRouter/` — add a small, real example tool to exercise the pattern, e.g. `SummarizeTool(model: RoutedLLM)` and an `EmbedTool(model: RoutedEmbedder)`, each holding the injected handle and calling `makeSession`/`embed`.
- Document the pattern (doc comment) on `RoutedLLM`/`RoutedEmbedder`: pass the slot handle into tool constructors; do not re-resolve per tool.
- Demonstrate that multiple tools constructed from the same resolved `LanguageModelProfile` share the identical resident model instance (no extra load).

## Acceptance Criteria
- [ ] Two tools built from `profile.flash` reference the same underlying resident model (assert identity/footprint accounting — no second load occurs; verify via the loader spy from milestone 5).
- [ ] A tool runs a generation/embedding through its injected handle and goes through the recorded chokepoint.
- [ ] Constructing tools does not change the active-profile residency (still one profile resident).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift` (Swift Testing) with the stub loader/recorder: two tools share one resident model (loader invoked once for the slot); a tool's call records a turn; residency unchanged.
- [ ] Run `swift test --filter ToolIntegrationTests` — all pass.

## Workflow
- Use `/tdd` — write the failing shared-instance + recorded-call tests first.

## Review Findings (2026-06-30 19:25)

- [x] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift:65` — Method name `recordLLMLoad` uses uppercase acronym in camelCase context; Swift conventions require acronyms at the start of camelCase to be lowercase except in type names. The related property `llmLoads` on line 61 correctly uses lowercase `llm`, creating inconsistency. Rename to `recordLlmLoad`. — RESOLVED (case a, test-only spy method): renamed method `recordLlmLoad` and its sole call site in `StubModelLoader.loadLLM`.
- [ ] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift:80` — Property name `totalRAM` uses uppercase acronym in camelCase context. Swift conventions require acronyms to follow camelCase rules: lowercase-first when not in type names. Rename to `totalRam`. — UNSATISFIABLE IN SCOPE (case b, protocol conformance): `StubProbe.totalRAM: Int64` is the stored property that satisfies the `MachineProbe` protocol requirement `var totalRAM: Int64 { get }` (milestone 1, `Sources/FoundationModelsRouter/Sizing/HostProfile.swift`). There is no test-local variable to rename — the property name IS the conformance, and the `StubProbe(totalRAM:)` memberwise-init label derives from it. Renaming would require a project-wide production acronym-rename of the accepted `MachineProbe` API, which is out of scope for milestone 6. Left unchanged; reported to the user.
- [x] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift:107` — Property name `configJSON` uses uppercase acronym in camelCase context. Swift conventions require acronyms to follow camelCase rules: lowercase-first except in type names. Rename to `configJson`. — RESOLVED (case b, test-local static): renamed the test-local `private static let` to `configJson`; the production `RawRepoMetadata(configJSON:)` argument label is kept at the call site (`RawRepoMetadata(configJSON: configJson, treeJSON: treeJson)`).
- [x] `Tests/FoundationModelsRouterTests/ToolIntegrationTests.swift:113` — Property name `treeJSON` uses uppercase acronym in camelCase context. Swift conventions require acronyms to follow camelCase rules: lowercase-first except in type names. Rename to `treeJson`. — RESOLVED (case b, test-local static): renamed the test-local `private static let` to `treeJson`; the production `RawRepoMetadata(treeJSON:)` argument label is kept at the call site.

_Note: 4 further engine findings (test-stub duplication in LoaderSpy at :65 and repeated test-setup boilerplate at :183/:213/:237) were dropped under the review skill's test exception — test-stub duplication was explicitly declared out of scope for this task._