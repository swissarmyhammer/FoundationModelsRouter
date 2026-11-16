---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7jn5qr2kjdz33kza19t0n7d
  text: |-
    Research done.
    - Sizing: `Router.sizeCandidates(profile:)` (no pool, no admission job). The estimate calls it directly.
    - Joint fit: `Router.runJointFit` wraps `JointFit.resolve` with the footprint and native-context closures, and records failures into the progress. Plan: extract the pure part into one private static function (`jointResolution(profile:budget:metadataByRef:residentKeys:)`). `runJointFit` keeps the progress records and calls it. The estimate calls it with `residentKeys: []` and the machine budget (`hostBudget()`), so no pool subtraction and no resident discount.
    - requiredBytes: the sum of `chargedBytes` of the chosen report of each slot. This is what JointFit charged against the budget, so it is <= budgetBytes.
    - failure: `String(describing:)` of the `ResolutionFailure` or `NoWindowFailure`, the same text that a resolve puts in `ResolutionProgress.Phase.failed`. A metadata error shows as "metadata unavailable (<reason>)" in that text.
    - Decision: the estimate does not run `DecisionSlotPlan` (the read of the decision prompt format). That read is not sizing and it can read more files from the Hub.
    - Decision: cancellation. A cancelled task gets fits false and the failure "the estimate was cancelled" (checked before and after the sizing). The function does not throw.
    - Test stubs: `RouterTestFixtures.makeRouter`, `ResidencyFixtures.makeRouter` + `LoadSpy` + `SpyingModelLoader`, `StubMetadataSource`. Pool check: `router.pool.admittedFootprint.resident`.
    - No DocC page for Router exists; the root page `FoundationModelsRouter.md` has Topics. Add a resolution group there.
  timestamp: 2026-11-16T17:06:15.938724+00:00
- actor: claude-code
  id: 01m7jnj2er87mr1m8m3bfegq7b
  text: |-
    Implementation done (TDD). RED: `swift build --build-tests` failed with "value of type 'Router' has no member 'estimateFit'". GREEN: `swift test --filter "EstimateFitTests|ProfileFitEstimatePublicSurfaceTests"` gave 11 + 1 tests pass. The public surface test was written after the API existed. It is a compile-level check of the public access of each field.
    Discovery: the builtin decision candidate is a GGUF file. The stub metadata source does not read a GGUF header, so the builtin test sets the decision slot to the flash candidates of the profile.

    ### implement — changed
    - evidence: full `swift test` once, exit 0: 2837 tests in 330 suites, 48 tests in 26 suites, 19 tests in 3 suites, all pass, 0 warnings. Files: Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Resolution/ProfileFitEstimate.swift (new), Sources/FoundationModelsRouter/FoundationModelsRouter.docc/FoundationModelsRouter.md, Tests/FoundationModelsRouterTests/EstimateFitTests.swift (new), Tests/FoundationModelsRouterPublicSurfaceTests/ProfileFitEstimatePublicSurfaceTests.swift (new)
    - next: /review
  timestamp: 2026-11-16T17:13:00.120815+00:00
position_column: doing
position_ordinal: '80'
title: 'Router.estimateFit(of:): fit estimate with no download and no load (ROUTER-12, D189)'
---
## Goal
Add `public func estimateFit(of profile: ProfileDefinition) async -> ProfileFitEstimate` on `Router`. It runs the same sizing and the same `JointFit` as `resolve(profile:reporting:)` against the machine budget. It does not subtract the models in the pool. It downloads no model and loads no model. It can read the repository metadata (the same read as the sizing of a resolve). It does not throw: a sizing error goes into `failure`. Source: TestudoApp ec3296d, ROUTER-12 and D189.

## API
New public value `ProfileFitEstimate: Sendable, Equatable` (put it in its own file, for example `Resolution/ProfileFitEstimate.swift`):
- `fits: Bool`
- `requiredBytes: Int64?` (the total bytes of the chosen fit; nil when no fit or the sizing fails)
- `budgetBytes: Int64` (the machine budget, with no pool subtraction)
- `chosen: [ModelSlot: ModelRef]` (the candidate that each slot chose; empty when it does not fit)
- `failure: String?` (the readable reason when it does not fit or when the sizing fails)

## Rules
- Reuse the code of the sizing and of JointFit of the resolve. Do not copy it. Extract a shared function if necessary.
- Resolve local model paths (`resolvingLocalModelPaths()`) the same as resolve.
- No admission job of the pool, no hold, no progress object, no loader call.
- Cancellation: if the task is cancelled, give an estimate with fits false and a failure. Or follow the existing pattern; decide yourself and document it.

## Design (decided in the implementation)
- `Router.jointResolution(profile:budget:metadataByRef:residentKeys:)` (private static) holds the pure `JointFit.resolve` call with its footprint and native-context closures. `runJointFit` (resolve) and `estimateFit` (estimate) both call it. The estimate calls the same `sizeCandidates(profile:)` as the resolve.
- The estimate uses `hostBudget()` and `residentKeys: []`: no pool subtraction and no resident discount.
- `requiredBytes` is the sum of the `chargedBytes` of the chosen candidate of each slot.
- `failure` is the `description` of the `ResolutionFailure` or `NoWindowFailure`, the same text as `ResolutionProgress.Phase.failed` of a resolve.
- The estimate does not run `DecisionSlotPlan` (the read of the decision prompt format). That read is not sizing.
- Cancellation: the estimate checks `Task.isCancelled` before and after the sizing. A cancelled task gets fits false and the failure "the estimate was cancelled".
- `ProfileFitEstimate` has two internal initializers (fit and no fit), so a value with fits true and a failure cannot exist.

## Tests (TDD, Swift Testing, no .timeLimit; no network: HubRequestGuard is armed)
- [x] A stub metadata source and a large budget: fits == true, one chosen model for each of the four slots, requiredBytes not nil and <= budgetBytes.
- [x] A small budget: fits == false, chosen is empty, failure is not nil.
- [x] A sizing error from the metadata source: fits == false and failure has the reason.
- [x] The estimate calls no loader (a loader stub that records calls stays at zero calls) and the pool stays empty.
- [x] A model resident in the pool does not change budgetBytes.
- [x] Use ModelProfiles.builtin profiles in at least one test, if that task is done first.
- [x] Add the new public names to the public surface test if there is one; DocC topics for Router. #router-12