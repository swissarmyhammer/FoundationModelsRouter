---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: Use InMemoryTracer.finishedSpans(named:) for each span-name filter in the tests
---
## What
Task ^a9dkcbk added `InMemoryTracer.finishedSpans(named:)` in `Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift`. The decide, embed, session and submission filters use it now. Other test files still copy the filter `tracer.finishedSpans.filter { $0.operationName == ... }`:

- `ResolveTracingTests.swift`, `ToolTracingTests.swift`, `CompactionTracingTests.swift`
- `GenerationCallOutputBufferedTests.swift`, `GenerationCallFirstTokenTests.swift`, `GenerationCallTracingTests.swift`
- `RecordedForkTreeRestoreTests.swift`, `EnterRecordTests.swift`

Replace each copy with a call to `finishedSpans(named:)`. Do not change what a test asserts.

## Acceptance Criteria
- [ ] No test file filters `finishedSpans` by `operationName ==` itself.
- [ ] Run `swift test` once. All tests pass. #decision