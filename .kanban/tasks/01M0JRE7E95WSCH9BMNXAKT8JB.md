---
assignees:
- claude-code
position_column: todo
position_ordinal: '8e80'
title: The usageTokenCounts() doc comment in LiveModelLoader.swift says the gated suite never ran; it runs and it is green
---
The doc comment on `MLXFoundationModelsSessionBackend.usageTokenCounts()` in `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift` says: "that suite needs a GPU and network access this sandbox does not have, so it has never actually run here; it only ever reports skipped", and that whether the executor populates non-zero `usage.input`/`usage.output` totals "has not been empirically confirmed in this environment". That text is stale.

Measured 2026-08-21 on this machine, `swift test --package-path IntegrationTests --filter LanguageModelSessionBackendIntegrationTests`: 11 tests in 1 suite passed. `secondTurnReusesFirstTurnsKVCache` printed `turn1In=49 turn1Out=93 turn2Cached=50`, and `recordedTokenUsageMatchesLiveBackendDelta` printed `tokensIn=62 tokensOut=149`. The totals are populated and positive; the suite runs and is green. Found while card ^de1yq0p worked that test.

## What to build

- Rewrite the "Empirical status" paragraph of that doc comment so it states what is measured: the gated suite runs on a machine with the model, `usage.input.totalTokenCount` and `usage.output.totalTokenCount` are positive, and `usage.input.cachedTokenCount` is positive on turn 2 (see `secondTurnReusesFirstTurnsKVCache`). Keep the turn-lock precondition text. Name the revision of the fork and the date of the measurement.
- Keep the doc comment in ASD-STE100 Simplified Technical English. Do not change code.

## Acceptance Criteria

- [ ] The doc comment no longer says the suite never ran or only reports skipped
- [ ] The doc comment names the measured facts, the fork revision, and the date
- [ ] Root `swift test` stays green #integration #real-model