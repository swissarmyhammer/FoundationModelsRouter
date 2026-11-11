---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76fvjd31rjag55wry9stxt5
  text: |-
    Implementation done. Discoveries and changes:
    - The private wrappers `spans(named:in:)` in `ResolveTracingTests.swift` and `ToolTracingTests.swift` only forwarded to the filter. I removed them. The callers call `tracer.finishedSpans(named:)` directly.
    - `EnterRecordTests.swift` and `TelemetryContentSafetyTests+FailedSpans.swift` filtered `context.spans`. `TelemetryCapture.Context.spans` is `tracer.finishedSpans`, and `W3CInMemoryTracer.finishedSpans` is `inMemoryTracer.finishedSpans`. Thus they now call `context.tracer.inMemoryTracer.finishedSpans(named:)`. The filter of `activeSpans` in `EnterRecordTests.swift` stays: it reads open spans, not finished spans.
    - grep found more copies with `.first { $0.operationName == ... }` and `.contains { $0.operationName == ... }`: `GenerationCallFirstTokenTests.swift`, `CoreMLEmbeddingThroughRouterTests.swift`, `WatchStopUsageTests.swift`, `SessionTracerWiringTests.swift`, `TelemetryContentSafetyTests.swift`. They now use `finishedSpans(named:).first`, `.first { other condition }` or `.isEmpty`. The assertions are the same.
    - One copy stays in `IntegrationTests/.../CrossRouterPoolIntegrationTests.swift` (`loadSpans`). The nested `IntegrationTests` package cannot see the helper in the unit test target. To share it, the helper must move to `FoundationModelsRouterTestSupport`, and that target must link `InMemoryTracing`. That changes the package graph, so I made the new task ^g10az... see "Use a shared finishedSpans(named:) helper in the integration tests" (01M76FV5JN2ZG10AZTG4NN39EA).
    - `swift test` (one run): 2638 tests in 305 suites passed, 41 tests in 23 suites passed, 19 tests in 3 suites passed. Exit 0. The only warning is the build-system notice "missing creator for mutated node" for the mlx-swift_Cmlx bundle; it does not come from the test code.
  timestamp: 2026-11-11T23:42:26.723318+00:00
- actor: claude-code
  id: 01m76fvvfx1q3xnzcmax6336bv
  text: |-
    Correction to the comment above: the short id of the new task is ^4nn39ea.

    ### implement — changed
    - evidence: 13 files in Tests/FoundationModelsRouterTests — ResolveTracingTests.swift, ToolTracingTests.swift, CompactionTracingTests.swift, GenerationCallOutputBufferedTests.swift, GenerationCallFirstTokenTests.swift, GenerationCallTracingTests.swift, RecordedForkTreeRestoreTests.swift, EnterRecordTests.swift, TelemetryContentSafetyTests+FailedSpans.swift, TelemetryContentSafetyTests.swift, WatchStopUsageTests.swift, CoreMLEmbeddingThroughRouterTests.swift, SessionTracerWiringTests.swift; `swift test` once: 2638 + 41 + 19 tests passed, exit 0.
    - next: /review. The integration-test copy is in ^4nn39ea.
  timestamp: 2026-11-11T23:42:36.029663+00:00
- actor: claude-code
  id: 01m76fzrv2cvmej4k39e2adpnr
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a58d4717). 0 findings, 0 confirmed, 0 refuted. 13 files reviewed. 6 files in .kanban/ not reviewed (.reviewignore).
    - next: none. The task is in done.
  timestamp: 2026-11-11T23:44:44.386381+00:00
- actor: claude-code
  id: 01m76g07r6h93v78h8ypqk566j
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 13 test files use InMemoryTracer.finishedSpans(named:); new task ^4nn39ea for the integration-test copy
    - test: green — swift test, 2638 + 41 + 19 passed, 0 skipped
    - commit: a58d4717
    - review: clean — 0 findings
  timestamp: 2026-11-11T23:44:59.654002+00:00
position_column: done
position_ordinal: ffffffffff8680
title: Use InMemoryTracer.finishedSpans(named:) for each span-name filter in the tests
---
## What
Task ^a9dkcbk added `InMemoryTracer.finishedSpans(named:)` in `Tests/FoundationModelsRouterTests/Helpers/InMemoryTracer+FinishedSpans.swift`. The decide, embed, session and submission filters use it now. Other test files still copy the filter `tracer.finishedSpans.filter { $0.operationName == ... }`:

- `ResolveTracingTests.swift`, `ToolTracingTests.swift`, `CompactionTracingTests.swift`
- `GenerationCallOutputBufferedTests.swift`, `GenerationCallFirstTokenTests.swift`, `GenerationCallTracingTests.swift`
- `RecordedForkTreeRestoreTests.swift`, `EnterRecordTests.swift`

Replace each copy with a call to `finishedSpans(named:)`. Do not change what a test asserts.

## Acceptance Criteria
- [x] No test file filters `finishedSpans` by `operationName ==` itself.
- [x] Run `swift test` once. All tests pass. #decision