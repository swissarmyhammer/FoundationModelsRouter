---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0jz90sh56fhnfyed2bca7ad
  text: |-
    Picked up. Research: the stale claim stands in one file only. `rg -n "could not be executed live|never actually set against|verified to \*compile\*|report back|no GPU/Apple Silicon" Sources Tests IntegrationTests` matched four lines, all in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift`, the suite doc comment. The three-run table in `GatedSuiteSerialGate.swift` (16.7, 40.9, 101.5 for this test) is a true record of 2026-08-20 and stays.

    Measured run, 2026-08-21, Apple silicon Mac, model in the Hugging Face cache:
    - command: `swift test --package-path IntegrationTests --filter RecordingHandleIntegrationTests`
    - result: PASS. `Test run with 1 test in 1 suite passed after 21.434 seconds.` The gated-test log line states `wallClockSeconds=21.4`.
    - whole command wall clock, build included: 29.9 seconds (`real 0m29.911s`).
    - mlx-swift-lm fork revision from `IntegrationTests/Package.resolved`: `41e9f41c9121e11f85146e9f5a4d89f6f840f2d3` (branch `stable`).

    Change: doc only. The IMPORTANT paragraph is rewritten to state those facts. The 2026-08-20 timing paragraph stays and now also states the 2026-08-21 number, 21.4 seconds. No code line changed.
  timestamp: 2026-08-21T20:12:56.497890+00:00
- actor: claude-code
  id: 01m0jz9fbb7vjbf5jgt32t58s7
  text: |-
    ### implement — changed
    - evidence: 1 file — `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift` (suite doc comment only; no code line changed). Suite run 2026-08-21: `swift test --package-path IntegrationTests --filter RecordingHandleIntegrationTests` PASS, 1 test in 1 suite, 21.434 s test wall clock, 29.9 s whole command, fork revision `41e9f41` (`41e9f41c9121e11f85146e9f5a4d89f6f840f2d3`, branch `stable`). `swift build --build-tests --package-path IntegrationTests`: Build complete, exit 0. Root `swift test`: `Test run with 1032 tests in 98 suites passed after 5.384 seconds with 2 known issues` (FoundationModelsRouterTests) and `Test run with 80 tests in 10 suites passed after 0.181 seconds` (the eval target), exit 0, 0 failures. Post-edit sweep `rg -n "could not be executed live|never actually set against|verified to \*compile\*|report back|no GPU/Apple Silicon|this sandbox" Sources Tests IntegrationTests` matches nothing. Acceptance boxes ticked; tags `integration`, `real-model` re-supplied and verified with `get task`.
    - next: `/review`
  timestamp: 2026-08-21T20:13:11.403459+00:00
position_column: doing
position_ordinal: '80'
title: The RecordingHandleIntegrationTests.swift header says the suite could not run in this sandbox; the same header reports three timed runs of 2026-08-20
---
The suite doc comment on `RecordingHandleIntegrationTests` in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift` says: "IMPORTANT — this suite could not be executed live in this sandbox: there is no GPU/Apple Silicon and no network access here to download `recordingHandleTinyModel`, so a real-model run was never actually set against a real run. Everything below is verified to *compile* ... someone needs to run this suite on a real Apple Silicon Mac ... then confirm the assertions below hold and report back." The next paragraph of the same comment then says: "The three runs of 2026-08-20 measured this suite's one test at 16.7, then 40.9, then 101.5 seconds". The two paragraphs cannot both be true. The suite has run. Found while card ^xakt8jb corrected the same stale claim on `MLXFoundationModelsSessionBackend.usageTokenCounts()`.

## What to build

- Run `swift test --package-path IntegrationTests --filter RecordingHandleIntegrationTests` on a machine with the model. Record the result (pass or fail, test count, date, fork revision from `IntegrationTests/Package.resolved`).
- Rewrite the "IMPORTANT" paragraph so it states the measured facts: the suite runs on a machine with the model, the date, the fork revision, and the result. Remove every sentence that says the suite never ran or that its assertions are not confirmed.
- Keep the doc comment in ASD-STE100 Simplified Technical English. Do not change code.

## Acceptance Criteria

- [x] The header no longer says the suite could not run or that its assertions are unconfirmed
- [x] The header names the measured result, the fork revision, and the date
- [x] `swift build --build-tests --package-path IntegrationTests` compiles
- [x] Root `swift test` stays green #integration #real-model