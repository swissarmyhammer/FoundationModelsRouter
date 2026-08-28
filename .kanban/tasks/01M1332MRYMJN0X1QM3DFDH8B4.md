---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14dpgman4ntxa84d3w7yb7p
  text: |-
    Picked up. Research done, every consumer traced before the edit.

    Consumers of the listed symbols, outside `Sources/FoundationModelsRouter`:
    - `Examples/`, `Tools/`, `Tests/FoundationModelsRouterTestSupport`, `Tests/FoundationModelsRouterRealModelSupport`, `Tests/FoundationModelsRouterEvalSupport`: NO match for any of the six symbols. So no plain-import consumer forces `package`.
    - `IntegrationTests/`: one consumer only — `MergedTranscript.merged(under:)`, in `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift` and `RecordingHandleIntegrationTests.swift`. That file opens with `@testable import FoundationModelsRouter`, which crosses `internal`. So `internal` is correct and `package` would break it, as the card states.
    - Root `Tests/FoundationModelsRouterTests` (a `@testable` test target): uses `MergedTranscript`, `MergedTranscriptError`, `OperationEventSegment`, `transcriptSegment`, and `init?(schemaName:contentJSON:id:)`. All reachable at `internal`.

    In-module callers that keep each demoted member alive for `dead-code-swift` (periphery indexes the test targets under `--build-tests`):
    - `SessionOutbox.post(event:)` — witness of the ALREADY-internal `OperationEventSink` protocol (Hosting/OperationEventSink.swift), so an internal witness is legal. `ToolContext` posts through the protocol.
    - `SessionOutbox.post(invocation:)` — same protocol; `ToolRun.open()`/`close` and `ContextBindingTool` call it through `sink`.
    - `QueueDepth.init(queued:dispatched:)` — called by `SessionOutbox.queueDepth()`.
    - `PersistableStructuredSegment.schemaName` — read by `RouterSegmentSchemaNames.all`, `SessionTreeRestoration`, `TranscriptReconstruction`.
    - `PersistableStructuredSegment.init?(schemaName:contentJSON:id:)` — test-only caller, reachable under `@testable`.

    Two facts that shape the edit:
    1. `OperationEventSink` is already `internal`, so demoting the two `post` witnesses of the public `SessionOutbox` actor does not break the "a witness must be as accessible as the conformance" rule.
    2. `SessionOutbox`'s own doc comment states "The public surface is the vocabulary (ItemID, PromptQueueMutationResult, QueueDepth) plus the OperationEventSink conformance." After this demotion that sentence is false, so it is corrected in the same change.

    On TDD: this card changes access levels only. It adds no behaviour, so no test can fail before the edit and pass after it — a test that named a demoted symbol from a `@testable` target compiles the same on both sides. The compile IS the test here, and the card names the three commands that make it: `swift build`, `swift test`, and `swift build --package-path IntegrationTests --build-tests` (the cross-package proof that `MergedTranscript` stayed reachable under `@testable`).
  timestamp: 2026-08-28T14:52:04.106842+00:00
- actor: claude-code
  id: 01m14dvagwv320pf22cctv0ja8
  text: |-
    ### implement — changed
    - evidence: 4 source files. Twelve `public` keywords removed, none added.
      - `Sources/FoundationModelsRouter/Session/SessionOutbox.swift` — `post(event:)`, `post(invocation:)`, `QueueDepth.init(queued:dispatched:)`. `SessionOutbox`, `ItemID`, `PromptQueueMutationResult` and `QueueDepth` itself stay public, as the card directs.
      - `Sources/FoundationModelsRouter/Session/OperationEventSegment.swift` — the struct, `id`, `content`, `init(id:content:)`, `description`.
      - `Sources/FoundationModelsRouter/Recording/PersistableStructuredSegment.swift` — the protocol, `schemaName`, `init?(schemaName:contentJSON:id:)`.
      - `Sources/FoundationModelsRouter/Recording/MergedTranscript.swift` — the enum and `merged(under:)`.
    - Commands, all three green:
      - `swift build` — Build complete. It builds the two example executables, the fixture tool and all three plain-import support targets, so no `package` widening was forced anywhere.
      - `swift test` — `Test run with 1072 tests in 110 suites passed ... with 2 known issues`, plus `Test run with 83 tests in 10 suites passed`. Exactly the stated baseline. Zero failures.
      - `swift build --package-path IntegrationTests --build-tests` — Build complete. This is the cross-package proof: the nested package reads `MergedTranscript.merged(under:)` under `@testable import`, and `internal` keeps it reachable where `package` would not.
    - The second acceptance criterion is enforced by the compiler rather than by inspection: Swift refuses a public signature that names an internal type ("cannot be declared public because its result uses an internal type"), so a clean `swift build` IS the proof that no public signature names a demoted type.
    - One doc comment was corrected in the same change, because the demotion made it false. `SessionOutbox`'s header said its public surface was "the vocabulary ... plus the OperationEventSink conformance". Both `post` methods are now internal, so the header states instead that the vocabulary alone is public — `RoutedSession`'s own public methods carry those three types in their signatures — and that every method of the actor is internal, the `OperationEventSink` conformance included.
    - Nothing else was touched. No `package` was used, so no consumer forced a wider level than `internal`.
    - next: ready for `/review`.
  timestamp: 2026-08-28T14:54:41.692765+00:00
position_column: doing
position_ordinal: '80'
title: Demote the mistakenly public Session and Recording plumbing
---
## What

Demote the Session and Recording plumbing the audit found. Every consumer is a unit test under `@testable import`, which crosses `internal`. The Resolution symbols that were in this task are now a separate task, because they need `package` rather than `internal` and that is a different policy call.

To `internal`:
- `SessionOutbox.post(event:)` (Sources/FoundationModelsRouter/Session/SessionOutbox.swift:107), `post(invocation:)` (line 176), and `QueueDepth.init(queued:dispatched:)` (line 317). The internal caller is `ToolContext`.
- `OperationEventSegment` and its public members (Sources/FoundationModelsRouter/Session/OperationEventSegment.swift:26, 28, 31, 42, 52).
- `PersistableStructuredSegment` (Sources/FoundationModelsRouter/Recording/PersistableStructuredSegment.swift:16, 37, 73). It is public only because `OperationEventSegment` conforms; demote the two together. The other conformer, `CompactionSegment`, is already `package`.
- `MergedTranscript` and `merged(under:)` (Sources/FoundationModelsRouter/Recording/MergedTranscript.swift:38, 55). The nested `IntegrationTests` package reads it under `@testable`, so `internal` is correct and `package` would break it.

The `SessionOutbox` actor itself stays public here; a later task hoists its nested types and demotes it.

## Acceptance Criteria
- [x] Each listed symbol is `internal`.
- [x] No public signature in the module names a demoted type.

## Tests
- [x] Run `swift build` and `swift test` at the root. All targets build and all tests pass.
- [x] Run `swift build --package-path IntegrationTests`. It builds, which proves `MergedTranscript` stayed reachable under `@testable`.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup