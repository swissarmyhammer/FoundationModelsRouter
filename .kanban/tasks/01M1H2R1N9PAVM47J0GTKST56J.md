---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1hd0sxdc5f2yeyax145d29s
  text: |-
    Picked up. Research:
    - The real type is `RoutedModel<Container>` in `Sources/FoundationModelsRouter/LanguageModelProfile.swift`. `RoutedLLM` is `public typealias RoutedLLM = RoutedModel<any LoadedLLMContainer>` in the same file. The card name `RoutedModel` is the class. `RoutedLLM` is the alias the integration proof must use.
    - `resolution` is `package let resolution: SlotResolution`. `SlotResolution.contextTokens` is `package let` in `Resolution/SlotResolution.swift`. Both stay `package`.
    - `RoutedLLM.makeSession` reads `resolution.contextTokens`. `Router` writes `resolution.contextTokens` to the sidecar. The new property is a computed forwarder, so there is one source of truth.
    - `ResolveTests.profile` omits `context`, so its context is `ProfileDefinition.defaultContext` (8192). The ladder test derives 32_768 from a native max of 131_072.
    - The nested `IntegrationTests` package gates by package, not by `.enabled(if:)`. The sibling `ToolCallAttachmentSurfaceTests.swift` is not gated and has a 1 minute time limit. The new file follows that shape.
    - No `.swiftlint.yml` in the repo. Rules read: missing docs on public items, no magic numbers outside declarations, no dead code, no trivial assertions.
  timestamp: 2026-09-02T15:50:20.333423+00:00
- actor: claude-code
  id: 01m1hd7ajrxh0fysyssvbe71ag
  text: |-
    ### implement — changed
    - TDD: the three new assertions and the new integration file were written first. `swift build --build-tests` failed with `value of type 'RoutedLLM' ... has no member 'contextTokens'` at each new line (RED). Then `public var contextTokens: Int { resolution.contextTokens }` was added to `RoutedModel` (GREEN).
    - The real type name is `RoutedModel<Container>`; `RoutedLLM` and `RoutedEmbedder` are its public typealiases. The proof file uses `RoutedLLM`.
    - `resolution` and `SlotResolution.contextTokens` stay `package`. `makeSession` and the sidecar write still read `resolution.contextTokens`; the public property is a forwarder, so there is one source of truth.
    - evidence: 3 files — Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterTests/ResolveTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RoutedModelContextTokensSurfaceTests.swift
    - `swift build 2>&1`: Build complete, no warning from this repository.
    - `swift test 2>&1` (full, root): 1182 tests in 130 suites passed with 2 known issues (pre-existing `withKnownIssue` cases in RealModelHarness.swift and BoundedWait.swift), plus 83 tests in 10 suites in the eval target. Both `ResolveTests` cases passed. No warning from this repository.
    - `swift build --package-path IntegrationTests --build-tests 2>&1`: Build complete, no warning from this repository.
    - `swift test --package-path IntegrationTests --filter RoutedModelContextTokensSurfaceTests`: the filter matched; 1 test in 1 suite passed.
    - The only warning line in every run is the build system's `missing creator for mutated node`, which is not from this repository.
    - next: `/review`
  timestamp: 2026-09-02T15:53:54.008712+00:00
- actor: claude-code
  id: 01m1hhcp5zxdmdac7r36d9se6g
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (checkpoint 591504a), 3 files reviewed, 0 findings, 0 confirmed, 0 refuted, 7 validators attempted
    - next: none. The card moves to `done`.
  timestamp: 2026-09-02T17:06:44.031443+00:00
- actor: claude-code
  id: 01m1hhjatae620fx62pq32ksj9
  text: |-
    ### finish iteration 1 — review clean, card in `done`
    - implement: changed (from the previous loop run, not run again) — 3 files: Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterTests/ResolveTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RoutedModelContextTokensSurfaceTests.swift
    - test: green — `swift build 2>&1` complete, no warning from this repository; `swift test 2>&1` 1182 tests in 130 suites passed with 2 known issues, plus 83 tests in 10 suites passed; `swift build --package-path IntegrationTests --build-tests 2>&1` complete, no warning from this repository; `swift test --package-path IntegrationTests --filter RoutedModelContextTokensSurfaceTests` matched 1 test in 1 suite, passed
    - commit: 591504a
    - review: clean — `review sha HEAD~1..HEAD`, 3 files reviewed, 0 findings
  timestamp: 2026-09-02T17:09:49.002799+00:00
position_column: done
position_ordinal: ffffbb80
title: 'Ask 3: expose the resolved working context as public RoutedModel.contextTokens'
---
## What
Add a public read of the resolved working context, in tokens, to `RoutedModel`.

Files:
- `Sources/FoundationModelsRouter/LanguageModelProfile.swift`: add `public var contextTokens: Int { resolution.contextTokens }` to `RoutedModel`, beside `chosen` and `footprintBytes`. Keep `resolution` at `package` access. Write a doc comment that says this is the value the resolution ladder selected, and that it can be smaller than `ProfileDefinition.context` (see `Resolution/JointFit.swift:548`). Say that every slot of one profile shares the same value.
- The same value is what `RoutedLLM.makeSession` gives the session actor as `contextTokens` (`Sources/FoundationModelsRouter/RoutedLLM.swift:203`) and what `Router` writes to the sidecar `context` field (`Router.swift:919`). Do not add a second source of truth.
- The `public` proof must live in the nested `IntegrationTests/` package. The root test target is in the same package as the library, so a `package` symbol is reachable there with a plain `import`; only a separate package proves `public`. Add a small hermetic file `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RoutedModelContextTokensSurfaceTests.swift` with a plain `import FoundationModelsRouter` (no `@testable`) that references `RoutedLLM.contextTokens` and builds `TokenBudget(limit:)` from it inside a function the compiler must type-check. Compilation is the assertion; the test body can be trivially green and gated like its neighbours.

Motivation: the ACP agent must build `TokenBudget(limit:)` at `session/new` before `makeSession`. Only the resolved value is correct.

## Acceptance Criteria
- [x] `RoutedModel.contextTokens` is declared `public`, and the nested `IntegrationTests` package compiles a plain-`import` reference to it.
- [x] The value equals `SlotResolution.contextTokens` of the slot that won.
- [x] When the ladder selects a smaller context than `ProfileDefinition.context`, `contextTokens` reports the smaller value.
- [x] `SlotResolution` and `RoutedModel.resolution` stay at `package` access.

## Tests
- [x] `Tests/FoundationModelsRouterTests/ResolveTests.swift`: in `successResolvesTrioAndDrivesProgress`, assert `contextTokens` on each of the three handles equals the profile's context.
- [x] `Tests/FoundationModelsRouterTests/ResolveTests.swift`: in `routerDerivesContextViaLadderAndPrefersModelOuter`, assert `profile.standard.contextTokens` equals the derived rung, not the native max.
- [x] `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RoutedModelContextTokensSurfaceTests.swift`: the plain-`import` reach proof described above.
- [x] Run `swift build 2>&1`, `swift test --filter ResolveTests`, and `swift build --package-path IntegrationTests --build-tests 2>&1`. Expect zero warnings and all green. Use a display-name filter only when it is known to match (see memory: `swift-test-filter-false-pass`).

## Workflow
- Use `/tdd`: write the failing tests first, then implement to make them pass. #upstream-asks #router-api #api