---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: A real-model backend test exceeds its 120-second limit when the whole integration package runs
---
## What

The whole integration package failed one test on 2026-09-01:

```
✘ Test "a second respond() call on the same backend sees the first turn's content in context"
  recorded an issue at LanguageModelSessionBackendTests.swift:141:6:
  Time limit was exceeded: 120.000 seconds
✘ Test ... failed after 347.982 seconds with 1 issue.
✘ Test run with 29 tests in 14 suites failed after 958.437 seconds with 1 issue.
```

The test ran for 348 seconds against a limit of 120 seconds. The other 28 tests
passed.

The suite is `Gated real-model coverage: MLXFoundationModelsSessionBackend
(milestone 7)`. It drives `RealModels.standard`, which is
`Muse-Glimmer-30B-4bit`, 18 GB of weights.

## What to do

- State why the test takes more than 120 seconds. Two generations against an
  18 GB model may simply cost more than the limit allows on a loaded box.
- Decide whether the limit is wrong, or the test is.
- Do not raise the limit alone if the test does more work than it needs.

## Acceptance Criteria
- [ ] The cause of the overrun is stated, with a measurement.
- [ ] The whole integration package passes three times in a row.

## Tests
- [ ] Run `swift test --package-path IntegrationTests` three times.

## Note

Found while working task ^49dy082 (a compaction fold defect). The compaction
path is not involved: every compaction suite of the package passed in the same
run. #router #defect #flaky-test #real-model #ci