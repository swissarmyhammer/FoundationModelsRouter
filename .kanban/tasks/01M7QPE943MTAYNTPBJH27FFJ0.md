---
assignees:
- claude-code
depends_on:
- 01M7QMG7QQEHJX5BW7VGFNSTE0
position_column: todo
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

- [ ] A stub metadata source and a budget where the largest window is about 49K tokens: `fits == true`, `contextTokens` is about 49K.
- [ ] A budget where the largest window is 8K: `fits == false`, `contextTokens == nil`, `failure` names the window and the minimum.
- [ ] A model whose native window is 16K and fits at native: `fits == true`, `contextTokens == 16384`.
- [ ] `resolve(profile:)` with the 8K budget still resolves with the 8K window.
- [ ] Sanity numbers of `research.md`: Qwen3.5-9B 4-bit with `kvBits: 8` and the h2o decision model fits 16 GB with about 49K tokens; Qwen3.8-27B 4-bit does not fit 16 GB.

## After

Push when green. Send the sha to foundationmodelsacpagent-9e and testudoapp-9a. #d203