---
assignees:
- claude-code
position_column: todo
position_ordinal: 9f80
title: 'Delete the Scripts directory: the package structure, not a shell script, selects the tests'
---
The user reports the Scripts directory is useless. It holds one file, `Scripts/swift-test.sh`, whose only job is to fail a `swift test --filter`/`--skip` run that matched no test. That guard exists because test selection rides on name regexes. The durable shape removes the need for the script: selection by package structure.

## What

Make the test split structural, then delete the script:

- Create a nested package `IntegrationTests/Package.swift` in /Users/wballard/github/swissarmyhammer/FoundationModelsRouter and move the two real-model targets (`Tests/FoundationModelsRouterIntegrationTests`, `Tests/FoundationModelsRouterEvalIntegrationTests`) into it, with a local `path:`-based dependency on the root package. The root package then declares no integration target, so a plain `swift test` at the root runs ONLY hermetic tests by construction — no `--skip`, no regex, no script.
- Integration runs use the native selector: `swift test --package-path IntegrationTests` (whole set) or `--filter` inside that package for one tier.
- Delete `Scripts/swift-test.sh` and the `Scripts/` directory.
- Update `.github/workflows/ci.yml` (lines 18, 46, 76 reference the script) to call `swift test` for the unit job and `swift test --package-path IntegrationTests` for the real-model job.
- Update `README.md` (lines 102-105) and `Tests/.../GatedSuiteSerialGate.swift`'s doc comment to state the new commands.

Support code both sides need already lives in plain (non-test) targets (`FoundationModelsRouterTestSupport`, `FoundationModelsRouterRealModelSupport`, `FoundationModelsRouterEvalSupport`); the nested package consumes them as products of the root package. Widen to `public` where `package` cannot cross the boundary, with a stated reason per declaration.

## Acceptance Criteria

- [ ] Root `swift test` runs only hermetic tests (current counts: about 1020 + 77) with no selector argument
- [ ] `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` runs that tier (under 2 minutes)
- [ ] `Scripts/` does not exist, and `rg -l "swift-test.sh" --glob '!.build' --glob '!.kanban' .` finds no match
- [ ] `.github/workflows/ci.yml` calls the two native commands
- [ ] No environment variable and no name-regex selection anywhere in the split

## Tests

- [ ] `swift test` at the root passes and its output shows no IntegrationTests suite
- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` exits 0 at the root, and `swift build --build-tests` exits 0 in `IntegrationTests/`
- [ ] One run of the fast eval tier through `swift test --package-path IntegrationTests --filter CompactionEvaluationIntegrationTests` passes

## Workflow
- Use `/tdd` — the failing state is a root `swift test` that still sees integration suites; make the structure remove them, then one green run of each side.
#tests #test-debt #ci