---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7qr9twptkyvnzyx2t1v1x7n
  text: |-
    Research done.
    - ProfileFitEstimate is not Codable and has only internal inits. Thus a new field needs no decodeIfPresent and no public init default.
    - Plan: JointFit.resolve gets a minimum window (default 1, so resolve does not change). searchWindow uses min(minimum, native) as the floor of the search in place of 1. The explicit `context` path ignores the minimum: the window is the context of the author (as with a native window under the minimum).
    - estimateFit: on a ResolutionFailure with a minimum over 1, it runs the fit again from 1 token. When that fit finds a window, the failure names that window and the minimum ("the largest window that fits is 8,192 tokens; a profile needs 32,768").
    - Stub tests: budget = requiredBytes of the estimate at an explicit context (49,152 / 8,192), then the estimate with a derived context. The charge is linear in the window, so the window is exact.
    - Sanity numbers: real configs from the Hub (mlx-community/Qwen3.5-9B-4bit: 32 layers, 8 full_attention, 16 heads, 4 KV heads, head_dim 256, hidden 4096, shards 5,349,771,222 + 600,449,850; MTP 136,884,332). The h2o-lightning-4b Q4_K_M GGUF header (local cache): qwen35, 33 blocks, context 262,144, embedding 2,560, 16 heads, 4 KV heads, key/value length 256, full_attention_interval 4, ssm conv 4 / inner 4,096 / state 128 / groups 16; file 2,708,808,736 bytes.
  timestamp: 2026-11-18T16:37:08.118584+00:00
- actor: claude-code
  id: 01m7qs3gpbm48md2t6yjp1apax
  text: |-
    Implementation landed (not committed).
    - JointFit.resolve has `minimumWindow` (default `smallestWindow` = 1, which is now internal so Router can name it). The search floor is min(minimumWindow, native). computedWindow measures at the floor and the failed window (labels `between:and:`).
    - Router.estimateFit(of:minimumContextTokens:) gives the minimum to the fit. On a ResolutionFailure with a derived context, it runs the fit again from 1 token. When that finds a window W, the failure is "the largest window that fits is W tokens; a profile needs min(minimum, native)". The counts use the en_US locale so the text is the same on each machine.
    - An explicit `context` ignores the minimum (decision of this step): the window is the context of the author, as with a native window under the minimum. Existing tests use an explicit 8,192 context and stay green.
    - Sanity number: the `small` profile (Qwen3.5-9B 4-bit + MTP, kvBits 8, h2o decision, Qwen3 embedding) on a 16 GB working set (2/3 of RAM) gives 52,196 tokens with these fixtures; research says "about 49K". The test accepts 42,000...56,000. Medium (27B 4-bit) does not fit.
    - Test fixtures: new Helpers/QwenRepoFixtures.swift (real Hub configs and shard sizes); ResolveTests now uses it in place of its private copies (the 32 GB test still gives 18,849). GGUFHeaderFixtures has h2oLightningBytes from the real header.

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Resolution/JointFit.swift, Resolution/ProfileFitEstimate.swift, Router.swift, FoundationModelsRouter.docc/FoundationModelsRouter.md; Tests/FoundationModelsRouterTests/EstimateFitWindowTests.swift (new, 8 tests), ProfileFitSanityTests.swift (new, 2 tests), Helpers/QwenRepoFixtures.swift (new), Helpers/GGUFHeaderFixtures.swift, ResolveTests.swift; Tests/FoundationModelsRouterPublicSurfaceTests/ProfileFitEstimatePublicSurfaceTests.swift (+1 test). Full `swift test`: 2927 tests in 340 suites + 49 in 26 + 19 in 3, all passed, 0 issues, no compiler warnings.
    - next: /review
  timestamp: 2026-11-18T16:51:09.643268+00:00
- actor: claude-code
  id: 01m7qsb2fgxzgfaw7mkk44jp6v
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (0bab1e58): 14 findings. ProfileFitEstimatePublicSurfaceTests.swift:75 (test-integrity/no-test-cheating); GGUFHeaderFixtures.swift:182,184,186 and QwenRepoFixtures.swift:62,66,71,76,81,86,90,91,95,96 (code-hygiene/magic-numbers-swift).
    - checks of the orchestrator: all pass. The resolve path (Router.swift jointResolution call in runJointFit) gives no minimumWindow, so the default is JointFit.smallestWindow (1) and the floor is min(1, native) = 1, the same as before. contextTokens and requiredBytes come from the same resolution (the standard slot window and the charges at that window). The failure text names the largest window and the minimum.
    - next: correct the 14 findings in the newest Review Findings section, then review again.
  timestamp: 2026-11-18T16:55:17.232016+00:00
- actor: claude-code
  id: 01m7qsbst4yrzwxb9ne9gxtg2j
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — JointFit.swift, ProfileFitEstimate.swift, Router.swift, DocC page, 6 test files
    - test: green — swift test in the implement step, 2927 tests in 340 suites (+49, +19), 0 issues
    - commit: 0bab1e58
    - review: findings — ProfileFitEstimatePublicSurfaceTests.swift:75 (test cannot fail); magic numbers in GGUFHeaderFixtures.swift:182,184,186 and QwenRepoFixtures.swift:62-96
    - decision (orchestrator): a profile with an explicit `context` uses that window and is not held to the 32K minimum. The bundled profiles set no `context`.
  timestamp: 2026-11-18T16:55:41.124251+00:00
- actor: claude-code
  id: 01m7qsmvfv9g1q9av7zmbb2d77
  text: |-
    Review findings corrected (14 of 14).
    - Public surface test: the test is now "the default minimum window refuses a budget with a smaller window". It uses a canned metadata source (a tiny safetensors config with a native window of 131,072) and a profile with the same model in the four slots. The budget is the charge of the profile at an explicit context of 8,192 (an explicit context ignores the minimum), so the largest derived window is 8,192. The test asserts `!fits` and that `failure` contains "32,768". It reads public fields only. The probe now takes the budget as an init parameter. The old helper call with `minimumContextTokens: nil` is gone; the first test still calls `estimateFit(of:)` with no minimum argument, so the default stays source-compatible.
    - Proof that it can fail: with `minimumContextTokens: 1` the test failed ("Expectation failed: !estimate.fits && ..."); after the revert it passed.
    - QwenRepoFixtures: a private enum for each repository (Qwen38TwentySevenB, Qwen35NineB, Qwen3FourB, Qwen3Embedding) and a Qwen3 enum for the shared `num_key_value_heads` 8 and `head_dim` 128 (these were in the string literal, which swiftlint does not read, but they are the same cause). Each shard size has its own constant, because swiftlint also reads the elements of an array literal.
    - GGUFHeaderFixtures: h2oLightningBlocks (33), h2oLightningEmbeddingWidth (2,560), h2oLightningKeyValueHeads (4), each with the GGUF header field. The same cause in the file: `dflashTargetLayers = [1, 2, 3]` is now `Array(1...dflashTargetLayerCount)`.
    - Check: swiftlint `no_magic_numbers` with allowed_numbers [0, 1, -1, 100] gives no finding on the three files.

    ### implement — changed
    - evidence: Tests/FoundationModelsRouterPublicSurfaceTests/ProfileFitEstimatePublicSurfaceTests.swift, Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift, Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift. Full `swift test` (one run): 2927 tests in 340 suites, 49 in 26, 19 in 3, all passed, exit 0, no compiler warning (only the SwiftPM "missing creator for mutated node" build note of the mlx bundle, which was there before).
    - next: /review
  timestamp: 2026-11-18T17:00:37.755802+00:00
depends_on:
- 01M7QMG7QQEHJX5BW7VGFNSTE0
position_column: doing
position_ordinal: '80'
title: 'ROUTER-13: a profile fits only with a window of 32K tokens or more, and the fit estimate gives the window (D203)'
---
## Goal

A profile "fits this Mac" only when its four slots fit the budget with a context window of 32K tokens (32,768) or more. The host sees the window of the fit, so the UI can show it and the agent can pick the largest profile that fits. Decision D203 (`TestudoApp/features/decisions.md`, commit 4ab65e8). Brief: `../.briefs/profiles/router-brief.md`; overview `overview.md`; facts `research.md`.

Depends on nothing outside this package. The dependency on ^gfnste0 is only the order of work. FoundationModelsACPAgent ACPA-23 and TestudoApp ^xb07h02 wait for this task.

## Current behavior

- The budget is `recommendedMaxWorkingSetSize` (`Sizing/HostProfile.swift:66-68`, probe `:95-98`).
- `JointFit.smallestWindow = 1` (`Resolution/JointFit.swift:70-72`). `searchWindow` tries the native window, then 1 token, then the largest window between them (`:461-505`). Thus a profile "fits" with a window of a few thousand tokens.
- `ProfileFitEstimate` has `fits`, `requiredBytes`, `budgetBytes`, `chosen`, `failure`, and no window (`Resolution/ProfileFitEstimate.swift:12-32`).
- `Router.estimateFit(of:)` is at `Router.swift:284`. `resolve(profile:)` uses the same `JointFit`.

## Change (names are decided; ACPAgent uses them)

1. `public static let defaultMinimumContextTokens = 32_768` on `ProfileFitEstimate`.
2. `Router.estimateFit(of:minimumContextTokens:)` with the default `ProfileFitEstimate.defaultMinimumContextTokens`. Keep the call `estimateFit(of:)` source-compatible through the default.
3. When the native window of the chosen model is smaller than the minimum, the minimum is the native window.
4. When the largest window that fits is under the minimum: `fits == false`, `contextTokens == nil`, and `failure` names the window that fits and the minimum, for example "the largest window that fits is 12,288 tokens; a profile needs 32,768".
5. `ProfileFitEstimate` gets `public let contextTokens: Int?`: the window of the chosen fit, `nil` when the profile does not fit. `requiredBytes` is the charge at that window.
6. `resolve(profile:)` does not change. It keeps the search from 1 token, so a profile that the user selects on a small Mac still loads with the largest window that fits.
7. Keep `kvBits` in the sizing (`Sizing/KVCacheQuantization.swift`).

## Tests

- [x] A stub metadata source and a budget where the largest window is about 49K tokens: `fits == true`, `contextTokens` is about 49K.
- [x] A budget where the largest window is 8K: `fits == false`, `contextTokens == nil`, `failure` names the window and the minimum.
- [x] A model whose native window is 16K and fits at native: `fits == true`, `contextTokens == 16384`.
- [x] `resolve(profile:)` with the 8K budget still resolves with the 8K window.
- [x] Sanity numbers of `research.md`: Qwen3.5-9B 4-bit with `kvBits: 8` and the h2o decision model fits 16 GB with about 49K tokens; Qwen3.8-27B 4-bit does not fit 16 GB.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e and testudoapp-9a. #d203

## Review Findings (2026-11-18 10:51)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 9 file(s) reviewed, 3 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

> 1 file(s) not reviewed — no validator matched:
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/FoundationModelsRouter.md` — no validator matches this file

- [x] `Tests/FoundationModelsRouterPublicSurfaceTests/ProfileFitEstimatePublicSurfaceTests.swift:75` `test-integrity/no-test-cheating` — The test named 'a host gives the default minimum window to the estimate' asserts only that budgetBytes equals the budget the probe set. That value is an input the test already controls, so the assertion passes whatever minimum window the estimate uses. The test proves nothing about the minimum window, and it cannot fail if the minimum is ignored. Assert on the value that the minimum changes. For example, use a budget whose largest window is under 32,768 tokens and assert `!estimate.fits` with `estimate.failure` naming 32,768. Or assert that `estimate.contextTokens` is at least the minimum when `estimate.fits` is true. Keep the test inside the public surface only if it reads public fields.
- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:182` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:184` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:186` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:62` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:66` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:71` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:76` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:81` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:86` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:90` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:91` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:95` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
- [x] `Tests/FoundationModelsRouterTests/Helpers/QwenRepoFixtures.swift:96` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.
