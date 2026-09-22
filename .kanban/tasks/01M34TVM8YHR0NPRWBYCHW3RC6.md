---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34w7a466tketpv97x6ndpc8
  text: |-
    ### research
    - Sites found: `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift` (the constant, the `respond` doc, the counted `for` loop), `Sources/FoundationModelsRouter/Session/RoutedSession.swift:115` (the protocol doc that names the count), `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:399` (the test that asserts the cut-off).
    - `streamResponse` and `streamEvents` do not drain. Only `respond(to:maxTokens:)` drains. No other entry point names the count.
    - No document in the repo names the count outside these three files.

    ### implementation
    - Deleted `backgroundRunDrainRoundLimit`. The drain loop is now `while true` with its two exits: the cancellation guard and the `settleBackgroundRuns` guard.
    - Rewrote the `respond` doc in both source files: no count bounds the rounds; the drain ends when a round finds no background run to await.
    - Replaced `AlwaysSuspendingBackend` with `ScriptedBackgroundingBackend(backgroundingTurns:)`. It starts one run in each of its first N turns and none after. Each turn answers with its own text.
    - Replaced the cut-off test with `drainRunsUntilATurnStartsNoBackgroundWork`: N = 6 (the card's number, named `backgroundingTurnCount`), 7 prompts reach the backend, the answer is the seventh turn's, and the run plane is empty.
    - `swift test --filter RespondRunPlaneDrainTests`: 9 tests in 1 suite passed. `rg backgroundRunDrainRoundLimit` finds nothing.
  timestamp: 2026-09-22T15:37:18.214831+00:00
- actor: claude-code
  id: 01m34wbgayxfp2jncyj4xhc4pj
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift
    - next: test

    ### test — green
    - evidence: `swift test` — 1349 + 1 + 83 = 1433 tests in 156 suites passed, 0 failed, 0 skipped. The 2 "known issues" are deliberate `withKnownIssue` records in pre-existing tests (RealModelHarness.swift:72, BoundedWait.swift:114). No source warning; the one `warning:` line is SwiftPM's note about the `mlx-swift_Cmlx.bundle` dependency product, present on every build. `swift build --package-path IntegrationTests --build-tests` — Build complete.
    - next: commit

    ### commit — changed
    - evidence: 0424f22 refactor(session): delete backgroundRunDrainRoundLimit; the drain runs until no new background work starts
    - next: review
  timestamp: 2026-09-22T15:39:35.646465+00:00
- actor: claude-code
  id: 01m34wh0kmsb89sdvzftc5necq
  text: |-
    ### review — findings
    - evidence: 2 findings — Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:35, Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:136 (`review sha HEAD~1..HEAD`, counts: findings 2, confirmed 2, refuted 0)
    - next: implement — write `// swiftlint:disable:next no_unchecked_sendable` with the synchronization invariant above each `@unchecked Sendable` class
  timestamp: 2026-09-22T15:42:36.148075+00:00
position_column: review
position_ordinal: '80'
title: Delete backgroundRunDrainRoundLimit; the drain runs until no new background work starts
---
## Decision (from the owner, 2026-09-22)

`RoutedSessionActor.backgroundRunDrainRoundLimit` (4, `Session/RoutedSessionActorGeneration.swift:8`) is an invented count and must go. The drain after a turn runs until a round starts no new background work, or the caller cancels.

## Why

- No reason for 4 is recorded. It predates the 2026-08-25 vocabulary rename.
- The loop already has its exits: `settleBackgroundRuns` returns `false` when the run plane is empty, and the loop breaks (`:74, 92-94`); a cancellation breaks it (`:73`). The count only cuts off a model that starts more background work in every round, silently, with the runs still going.

## Sites

- `RoutedSessionActorGeneration.swift:4-8`: the constant and its doc. `:24-30`: the `respond` doc that names it. `:65` the `for _ in 0..<Self.backgroundRunDrainRoundLimit` loop.
- Any other `respond`-like entry point that drains (`streamResponse`, guided respond); search `backgroundRunDrainRoundLimit`.
- Tests that assert the fourth round ends the drain (`RespondRunPlaneDrainTests`).

## Do this

1. Delete the constant. Replace the counted `for` with a `while true` loop whose exits are the two that exist: no new background work, and cancellation.
2. Rewrite the docs that name the count.
3. Replace the test that asserts the cut-off with one where a scripted model starts a background run in each of 6 rounds and then none: the drain runs 7 rounds and the answer is the seventh turn's.
4. Do not add a count anywhere else.

## Acceptance

- `rg 'backgroundRunDrainRoundLimit'` finds nothing.
- The 7-round test passes. All tests pass. #compaction #limits

## Review Findings (2026-09-22 10:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 3 file(s) reviewed, 4 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

- [x] `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:35` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/RespondRunPlaneDrainTests.swift:136` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.