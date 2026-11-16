---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
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

## Tests (TDD, Swift Testing, no .timeLimit; no network: HubRequestGuard is armed)
- [ ] A stub metadata source and a large budget: fits == true, one chosen model for each of the four slots, requiredBytes not nil and <= budgetBytes.
- [ ] A small budget: fits == false, chosen is empty, failure is not nil.
- [ ] A sizing error from the metadata source: fits == false and failure has the reason.
- [ ] The estimate calls no loader (a loader stub that records calls stays at zero calls) and the pool stays empty.
- [ ] A model resident in the pool does not change budgetBytes.
- [ ] Use ModelProfiles.builtin profiles in at least one test, if that task is done first.
- [ ] Add the new public names to the public surface test if there is one; DocC topics for Router. #router-12