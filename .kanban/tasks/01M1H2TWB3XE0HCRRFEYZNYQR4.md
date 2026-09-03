---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1hhx2tcb5wtstqpqr5snxg6
  text: |-
    Research done. Findings:
    - `ToolCallAttachment` exists in `Sources/FoundationModelsRouter/Hosting/ToolCallAttachment.swift` (card 01M1H2T6A20GC8GPZ8SKYK3FXB landed). No blocker.
    - `ToolInvocationObserver` has one conformer: `RoutedSessionActor` in `RoutedSessionActorRunJournal.swift`. No test double under `Tests/` conforms to it, so no test sink needs `deliver(report:)`.
    - The outbox attaches its observer in `attachOutboxJournalIfNeeded()` at the top of the first turn. A report posted before any turn is dropped. The between-turns test must run one turn first.
    - `ULID` is visible to every router file through `@_exported import ULID` in `Core/ULID.swift`.
    - The five exhaustive `SessionEvent` switches are in `SessionProjection.apply`, `TurnOutcomeFold.apply`, `Examples/MultiModelGeneration/main.swift`, `ScriptedToolTurnComparisonTests`, and the nested `RealToolTurnComparisonTests`. Ask 1 has not landed; there is no sibling case to sit beside.
    - Test plan: `SessionOutboxTests` gets an actor observer double and an actor journal double; a plain `OperationEvent` posted after the report is the positive control that proves the report never entered the journal chain. `ToolInvocationLivenessTests` uses a two-round script (quick marker tool, then the gated tool) so the turn is provably in flight when the test posts the report after the first close record.
  timestamp: 2026-09-02T17:15:41.260320+00:00
- actor: claude-code
  id: 01m1hj9h9rpyyb5tms94re0gwh
  text: |-
    ### implement — changed
    - evidence: 14 files — Sources/FoundationModelsRouter/Session/SessionEvent.swift, Sources/FoundationModelsRouter/Session/OperationEventJournal.swift, Sources/FoundationModelsRouter/Session/SessionOutbox.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift, Sources/FoundationModelsRouter/Session/RoutedSession.swift, Sources/FoundationModelsRouter/Session/SessionProjection.swift, Sources/FoundationModelsRouter/Session/TurnOutcome.swift, Examples/MultiModelGeneration/main.swift, Tests/FoundationModelsRouterTests/SessionOutboxTests.swift, Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift, Tests/FoundationModelsRouterTests/SessionProjectionTests.swift, Tests/FoundationModelsRouterTests/TurnOutcomeTests.swift, Tests/FoundationModelsRouterTests/ScriptedToolTurnComparisonTests.swift, IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift
    - TDD: the 7 new tests were written first; `swift build --build-tests` failed with `cannot find type 'ToolCallReport' in scope` and `no exact matches in call to instance method 'post'`; then the production code made them pass.
    - `swift test --filter 'SessionOutboxTests|ToolInvocationLivenessTests|SessionProjectionTests|TurnOutcomeTests'`: 70 tests in 4 suites passed (all 7 new tests seen in the output).
    - `swift test 2>&1`: 1189 tests in 130 suites passed with 2 known issues (pre-existing `withKnownIssue` tests in BoundedWaitTests and RealModelHarness), plus 83 tests in 10 suites in the eval target. Zero failures, zero skips.
    - `swift build 2>&1` and `swift build --package-path IntegrationTests --build-tests 2>&1`: both complete. The only warning is `missing creator for mutated node`, which is not from this repo.
    - next: /review
  timestamp: 2026-09-02T17:22:29.304654+00:00
- actor: claude-code
  id: 01m1hk7ejeq29jx41ms6qm9j3y
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (checkpoint b3cff6e03c6dc2723e06901abbc42294a2b58a15) — 14 files reviewed, 0 findings, 0 confirmed, 1 refuted
    - next: none. The card moved to `done`.
  timestamp: 2026-09-02T17:38:49.550501+00:00
- actor: claude-code
  id: 01m1hkct1a7wx4mghtt9a9bar7
  text: |-
    ### finish iteration 1 — review clean, card moved to done
    - implement: changed — 14 files: SessionEvent.swift (ToolCallReport + case toolCallReport), OperationEventJournal.swift (deliver(report:)), SessionOutbox.swift (post(report:)), RoutedSessionActorRunJournal.swift (deliverLive), RoutedSession.swift (doc comments), no-op arms in SessionProjection.swift, TurnOutcome.swift, Examples/MultiModelGeneration/main.swift, ScriptedToolTurnComparisonTests.swift, RealToolTurnComparisonTests.swift; 7 new tests in SessionOutboxTests, ToolInvocationLivenessTests, SessionProjectionTests, TurnOutcomeTests
    - test: green — `swift build 2>&1` complete; `swift test 2>&1` 1189 tests in 130 suites passed with 2 pre-existing known issues, plus 83 tests in 10 suites passed; `swift build --package-path IntegrationTests --build-tests 2>&1` complete; zero repository warnings (only the external `missing creator for mutated node` line)
    - commit: b3cff6e03c6dc2723e06901abbc42294a2b58a15
    - review: clean — `review sha HEAD~1..HEAD`, 14 files, 0 findings, 1 refuted
  timestamp: 2026-09-02T17:41:45.130016+00:00
depends_on:
- 01M1H2T6A20GC8GPZ8SKYK3FXB
position_column: done
position_ordinal: ffffbc80
title: 'Ask 4b: add SessionEvent.toolCallReport and its observer, projection, outcome, and doc plumbing'
---
## What
Router half of Ask 4, step two: the event vocabulary. Define the live event that carries a call's attachments, and the actor-side delivery. The next card (4c) routes reports from the tool decorators into the outbox; this card stops at the outbox.

Files:
- `Sources/FoundationModelsRouter/Session/SessionEvent.swift`: add `public struct ToolCallReport: Sendable, Equatable { public let tool: String; public let op: String; public let correlationID: String; public let sessionID: ULID; public let attachments: [ToolCallAttachment]; public init(...) }` and `case toolCallReport(ToolCallReport)`. Doc: delivery-only, never recorded; emitted once per call, after the close `toolInvocation` record, only when the call attached at least one record; `correlationID` is the run's `completionToken`, the same value as the call's `ToolInvocationRecord.correlationID`, never a `Transcript.ToolCall.id`. Travels on `streamSessionEvents()` always and on the turn's stream when the call closes inside a turn.
- `Sources/FoundationModelsRouter/Session/OperationEventJournal.swift`: add `func deliver(report: ToolCallReport) async` to the Router-internal `ToolInvocationObserver` protocol.
- `Sources/FoundationModelsRouter/Session/SessionOutbox.swift`: add `func post(report: ToolCallReport) async` that forwards to `invocationObserver?.deliver(report:)`, beside `post(invocation:)`. Not staged, not journaled.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorRunJournal.swift`: implement `deliver(report:)` as `deliverLive(.toolCallReport(report))`.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift`: list the new case in both the `streamSessionEvents()` and the `streamEvents(to:maxTokens:)` doc comments.

One-line switch-arm additions (same no-op arms as the Ask 1 card; if Ask 1 landed first, add beside its case):
- `Sources/FoundationModelsRouter/Session/SessionProjection.swift`, `apply(_:)`.
- `Sources/FoundationModelsRouter/Session/TurnOutcome.swift`, `TurnOutcome.apply(_:)`.
- `Examples/MultiModelGeneration/main.swift`.
- `Tests/FoundationModelsRouterTests/ScriptedToolTurnComparisonTests.swift`.
- `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift`.
- Test sinks that conform to `ToolInvocationObserver` (grep `ToolInvocationObserver` under `Tests/`) get an empty `deliver(report:)`.

## Acceptance Criteria
- [x] `SessionOutbox.post(report:)` with an attached observer delivers the same `ToolCallReport` to `deliver(report:)`; with no observer it drops it; it stages nothing and journals nothing.
- [x] `RoutedSessionActor.deliver(report:)` yields `.toolCallReport` on `streamSessionEvents()`, and on the turn's stream when a turn is in flight (`currentTurnEventSink` set).
- [x] `SessionProjection.apply(.toolCallReport)` and `TurnOutcome.apply(.toolCallReport)` change no state.
- [x] The root package and the nested `IntegrationTests` package build with zero warnings.

## Tests
- [x] `Tests/FoundationModelsRouterTests/SessionOutboxTests.swift`: `post(report:)` reaches the observer; no staging; no journal write.
- [x] `Tests/FoundationModelsRouterTests/ToolInvocationLivenessTests.swift`: a report posted through the outbox mid-turn appears on the turn's stream after the close record; posted between turns it appears on `streamSessionEvents()`.
- [x] `Tests/FoundationModelsRouterTests/SessionProjectionTests.swift` and `TurnOutcomeTests.swift`: `apply(.toolCallReport(...))` is a no-op.
- [x] Run `swift build 2>&1`, `swift test`, and `swift build --package-path IntegrationTests --build-tests 2>&1`. Expect zero warnings and all green.

## Workflow
- Use `/tdd`: write the failing tests first, then implement to make them pass. #upstream-asks #hosting #streaming #api