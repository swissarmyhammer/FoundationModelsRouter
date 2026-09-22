---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m359d7v6wee94xjvy4q8q40y
  text: |-
    Research (implement, iteration 1):
    - The resolved ceiling flows as `responseTokenCeiling: Int?` through `generate` -> `runTurn` -> `runTurnWork` -> `runTurnAttempt` -> `recoverFailedAttempt`. Four callers in `RoutedSessionActorGeneration.swift` and `runDispatchedTurn` resolve it with `responseTokenCeiling(requested:contextTokens:)`. The resolved value alone cannot tell "the caller named the window size" from "the window default".
    - Plan: a new internal value type `ResponseTokenCeiling` (`requested`, `resolved`) replaces the `Int?` in that chain. The recording keeps the resolved `Int?`. `OverflowRetryTarget` gets a `Rule` enum: `.callerCeiling(Int)` keeps the ^m39wmx1 room rule; `.configuredTarget` sets the target to `budget.targetTokens` and leaves the budget unchanged. The log line and `CompactionResult.overflowRetryTarget` carry the rule.
    - Tests: the four AutoCompactionTests (`reactiveRetryRecovers...`, `reactiveRetrySurfaces...`, `hardCeilingFailsFast...`, `hardCeilingStillExceeded...`) and the two TurnCancellationTests are about the default path; they drop `retryableResponseCeiling`. The room tests keep their own ceiling. `AutoCompactionFixtures.retryableResponseCeiling` then has no user and is deleted.
  timestamp: 2026-09-22T19:27:43.974671+00:00
- actor: claude-code
  id: 01m359kwwprd8cr7tweg722f4r
  text: |-
    ### implement — changed
    - evidence: 9 files — Sources/FoundationModelsRouter/Session/ResponseTokenCeiling.swift (new), Sources/FoundationModelsRouter/Session/OverflowRetryTarget.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Compaction/Compactor.swift, Tests/FoundationModelsRouterTests/AutoCompactionTests.swift, Tests/FoundationModelsRouterTests/TurnCancellationTests.swift, Tests/FoundationModelsRouterTests/Helpers/AutoCompactionFixtures.swift
    - `ResponseTokenCeiling` (`requested`, `resolved`) replaces `Int?` in `generate` -> `runTurn` -> `runTurnWork` -> `runTurnAttempt` -> `recoverFailedAttempt`. The recording and the backend read `resolved`.
    - `OverflowRetryTarget.Rule`: `.callerCeiling(Int)` keeps the ^m39wmx1 room rule (room capped at target; not positive means no retry). `.configuredTarget` sets the target to `budget.targetTokens`; the retry compaction runs against the configured budget unchanged. `roomTokens` and `responseTokenCeiling` are `nil` under `.configuredTarget`. The `OverflowRetry` log line states the rule.
    - No new number in Sources. `AutoCompactionFixtures.retryableResponseCeiling` is deleted; the four AutoCompactionTests and the two TurnCancellationTests on the default path name no ceiling now. New tests: `overflowRetryWithNoCallerCeilingCompactsToTheConfiguredTarget`, `overflowRetryWithNoCallerCeilingKeepsTheConfiguredBudget`; the two room tests assert `.callerCeiling`.
    - `swift build --build-tests`: exit 0.
    - next: test
  timestamp: 2026-09-22T19:31:22.134935+00:00
- actor: claude-code
  id: 01m359mwxyjf5p2bnkwfrdj4wr
  text: |-
    ### test — green
    - evidence: `swift test` — 1358 tests in 145 suites passed (2 known issues are `withKnownIssue` marks that were there before this card), plus 1 and 83 tests in the other runs, 0 failed, 0 warnings; `swift build --package-path IntegrationTests --build-tests` — Build complete.
    - next: commit
  timestamp: 2026-09-22T19:31:54.942040+00:00
- actor: claude-code
  id: 01m359n3mfw69v6fkcm41kbrqd
  text: |-
    ### commit — changed
    - evidence: 252a981 feat(compaction): compact to the configured target when the caller named no ceiling
    - next: review
  timestamp: 2026-09-22T19:32:01.807040+00:00
- actor: claude-code
  id: 01m359wvrp7cqwpwt4jfj2at7g
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` — 0 findings, 0 confirmed, 3 refuted; 14 validator passes attempted, 0 failed; 8 files reviewed; 6 `.kanban/` files skipped by `.reviewignore`. No prior `## Review Findings` sections exist.
    - next: done
  timestamp: 2026-09-22T19:36:15.894614+00:00
- actor: claude-code
  id: 01m359x577ksmjyj5htg8sg73f
  text: |-
    ### finish iteration 1 — review clean, task in done
    - implement: changed — ResponseTokenCeiling.swift added; OverflowRetryTarget.swift, RoutedSessionActorTurnExecution.swift, RoutedSessionActorGeneration.swift, Compactor.swift, AutoCompactionTests.swift, TurnCancellationTests.swift, AutoCompactionFixtures.swift changed; `rg retryableResponseCeiling` finds nothing
    - test: green — `swift test`: 1358 tests in 145 suites passed, 0 failed, 0 warnings; `swift build --package-path IntegrationTests --build-tests`: Build complete
    - commit: 252a981
    - review: clean — `review sha HEAD~1..HEAD`: 0 findings
  timestamp: 2026-09-22T19:36:25.575717+00:00
position_column: done
position_ordinal: ffffe680
title: Overflow retry with no caller ceiling compacts to the configured target, then retries
---
## Decision (from the owner, 2026-09-22)

^m39wmx1 computes the overflow retry's target as `contextTokens − promptTokens − responseTokenCeiling`. A turn with no `maxTokens` gets the whole window as its ceiling, so the result is below zero and a default turn never retries after an overflow. The owner chose: when the caller named no ceiling, the retry compacts to `TokenBudget.targetTokens` and runs again one time. When the caller named a ceiling, the computed room stays as it is now.

## Sites

- `Sources/FoundationModelsRouter/Session/OverflowRetryTarget.swift`: the computation. It needs to know whether the ceiling came from the caller or is the window default.
- `Session/RoutedSessionActorTurnExecution.swift`: `recoverFailedAttempt`, and where `responseTokenCeiling(requested:contextTokens:)` resolves the ceiling. Carry "the caller named a ceiling" to the retry (for example, pass `requested: Int?` next to the resolved ceiling).
- `CompactionResult.overflowRetryTarget` and the `OverflowRetry` log line: say which rule chose the target (the caller's ceiling, or the configured target).
- Tests in `AutoCompactionTests` and `TurnCancellationTests` that set `AutoCompactionFixtures.retryableResponseCeiling` (1 token) only to make a retry happen. Decide for each: keep the ceiling if the test is about the caller-ceiling path; remove it if the test is about the default path.

## Do this

1. With no caller ceiling: the retry target is `budget.targetTokens`. Compact, then retry one time.
2. With a caller ceiling: keep ^m39wmx1's rule (computed room, capped at target; not positive means no retry).
3. Record the rule on the event and the log.
4. Add tests: a default turn (no `maxTokens`) that overflows compacts to the configured target and retries once; a turn with a ceiling keeps the computed room; the cancellation test for the reactive retry passes on the default path.
5. Do not add a number. The target is the host's `TokenBudget.target`.

## Acceptance

- A default turn that overflows retries once after a compaction to `targetTokens`.
- The three tests from ^m39wmx1 still pass.
- All tests pass. #compaction #limits