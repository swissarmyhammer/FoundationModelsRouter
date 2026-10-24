---
comments:
- actor: wballard
  id: 01m5pvybjc6n8cfktzz4bhkp0x
  text: 'Done. New requirement LanguageModelSessionBackend.replacingTranscript(_:tools:) (default forwards to replacingTranscript(_:)); MLX backend and HookLayeredSessionBackend override it. BackendCompactionSummarizer builds its blank backend with tools: []. SummarizerToolsTests: own-model summarizer pass sees zero tools; a tool call there runs no body and the compaction fails (SDK: unrecognized tool name). ScriptedToolCallingModel now answers in text on a pass with no tools (TelemetryContentSafetyTests relied on the summarizer calling the session tool). swift test: 2177+39+19 pass, 9 known issues.'
  timestamp: 2026-10-24T11:50:08.204561+00:00
position_column: done
position_ordinal: ffffffffc080
title: Give the own-model compaction summarizer no tools
---
## What

The compaction summarizer on the session's own model keeps the session's tools. If the model emits a tool call while it summarizes, a tool body runs inside a compaction. Give the summarizer no tools.

- `Sources/FoundationModelsRouter/Session/RoutedSessionActorCompaction.swift:427` (the own-model tier) uses `backend.replacingTranscript(empty)` (`:32`).
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:835-838` keeps the session's tools in that copy.
- The comment at `LiveModelLoader.swift:386` ("The call has no tools") is wrong for this tier. The flash tier has no tools (`LiveModelLoader.swift:134`), and it is correct.

- [x] Make the own-model summarizer backend a copy with an empty tool list (and the same model and prompt cache scope rules as today).
- [x] Make the comment at `:386` true for both tiers.

## Acceptance Criteria

- [x] The own-model summarizer session has zero tools (a test reads the tools of the backend that compaction uses).
- [x] A stub model that emits a tool call during summarization gets no tool body run. The call ends as the SDK ends a call with an unknown tool, and compaction reports its usual failure path.
- [x] The flash tier is unchanged.

## Tests

- [x] `Tests/FoundationModelsRouterTests/SummarizerSubmissionTests.swift` (or a new `SummarizerToolsTests.swift`): the criteria above.
- [x] `swift test` in FoundationModelsRouter: all tests pass, with no new warnings.

## Workflow

- Use `/tdd`: write the failing tests first, then implement until they pass.