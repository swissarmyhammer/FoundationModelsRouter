---
assignees:
- claude-code
position_column: todo
position_ordinal: 8c80
title: 'GGUFProfileIntegrationTests: use the shared IsolatedPoolRouter fixture'
---
## What
Task ^3mpxfe5 added `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/Support/IsolatedPoolRouter.swift`: a router over `LiveModelLoader` and a pool of its own, with `withResolved(_:_:)` (resolve, run the body, drop the profile, expect `awaitNoResidentModel()`) and `removeRoot()`.

The private `GGUFRouterFixture` of `GGUFProfileIntegrationTests.swift` has the same `root`/`pool`/`router` fields, the same `withResolved` and the same `removeRoot`. Make `GGUFRouterFixture` use `IsolatedPoolRouter` and delete the copy. `GGUFRouterFixture` also takes a `probe`, so add a `probe: any MachineProbe = SystemMachineProbe()` parameter to `IsolatedPoolRouter.init`.

## Acceptance Criteria
- [ ] `GGUFProfileIntegrationTests.swift` has no copy of the resolve/drain/remove code.
- [ ] `swift test --package-path IntegrationTests --filter 'GGUFProfileIntegrationTests|DecisionSlotIntegrationTests'` passes, and the test count is 7.

## Tests
- [ ] Run the command above once and read the count.