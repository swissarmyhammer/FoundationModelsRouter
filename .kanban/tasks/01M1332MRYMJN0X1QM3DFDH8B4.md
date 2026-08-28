---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Demote the mistakenly public Session, Recording, and Resolution plumbing
---
## What

Demote the remaining plumbing the audit found. The rule: `internal` when only `@testable` consumers exist; `package` when a plain-import target in this package needs the symbol. The nested `IntegrationTests` package uses `@testable import`, which crosses `internal` but not `package` — so do not use `package` for anything that package touches.

To `internal`:
- `SessionOutbox.post(event:)` (Sources/FoundationModelsRouter/Session/SessionOutbox.swift:107), `post(invocation:)` (line 176), and `QueueDepth.init(queued:dispatched:)` (line 317). The internal caller is `ToolContext`.
- `OperationEventSegment` and its public members (Sources/FoundationModelsRouter/Session/OperationEventSegment.swift:26, 28, 31, 42, 52).
- `PersistableStructuredSegment` (Sources/FoundationModelsRouter/Recording/PersistableStructuredSegment.swift:16, 37, 73). It is public only because `OperationEventSegment` conforms; demote the two together. The other conformer, `CompactionSegment`, is already `package`.
- `MergedTranscript` and `merged(under:)` (Sources/FoundationModelsRouter/Recording/MergedTranscript.swift:38, 55).
- `RealModelHarness.makeResolution(...)` (Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift:92).

To `package`:
- `SlotResolution` (Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:89) and `CandidateReport` (line 51). No test, example, or tool reads `CandidateReport`.
- `RoutedModel.resolution` (Sources/FoundationModelsRouter/LanguageModelProfile.swift:28), which is why `SlotResolution` was public.

## Acceptance Criteria
- [ ] Each listed symbol has the listed access level.
- [ ] No public signature in the module names a demoted type.

## Tests
- [ ] Run `swift build` and `swift test` at the root. All targets build and all tests pass.
- [ ] Run `swift build --package-path IntegrationTests`. It builds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup