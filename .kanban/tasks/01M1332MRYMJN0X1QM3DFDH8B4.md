---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
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
- [ ] Each listed symbol is `internal`.
- [ ] No public signature in the module names a demoted type.

## Tests
- [ ] Run `swift build` and `swift test` at the root. All targets build and all tests pass.
- [ ] Run `swift build --package-path IntegrationTests`. It builds, which proves `MergedTranscript` stayed reachable under `@testable`.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup