---
assignees:
- claude-code
position_column: todo
position_ordinal: 8d80
title: The RecordingHandleIntegrationTests.swift header says the suite could not run in this sandbox; the same header reports three timed runs of 2026-08-20
---
The suite doc comment on `RecordingHandleIntegrationTests` in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RecordingHandleIntegrationTests.swift` says: "IMPORTANT — this suite could not be executed live in this sandbox: there is no GPU/Apple Silicon and no network access here to download `recordingHandleTinyModel`, so a real-model run was never actually set against a real run. Everything below is verified to *compile* ... someone needs to run this suite on a real Apple Silicon Mac ... then confirm the assertions below hold and report back." The next paragraph of the same comment then says: "The three runs of 2026-08-20 measured this suite's one test at 16.7, then 40.9, then 101.5 seconds". The two paragraphs cannot both be true. The suite has run. Found while card ^xakt8jb corrected the same stale claim on `MLXFoundationModelsSessionBackend.usageTokenCounts()`.

## What to build

- Run `swift test --package-path IntegrationTests --filter RecordingHandleIntegrationTests` on a machine with the model. Record the result (pass or fail, test count, date, fork revision from `IntegrationTests/Package.resolved`).
- Rewrite the "IMPORTANT" paragraph so it states the measured facts: the suite runs on a machine with the model, the date, the fork revision, and the result. Remove every sentence that says the suite never ran or that its assertions are not confirmed.
- Keep the doc comment in ASD-STE100 Simplified Technical English. Do not change code.

## Acceptance Criteria

- [ ] The header no longer says the suite could not run or that its assertions are unconfirmed
- [ ] The header names the measured result, the fork revision, and the date
- [ ] `swift build --build-tests --package-path IntegrationTests` compiles
- [ ] Root `swift test` stays green #integration #real-model