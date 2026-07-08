---
assignees:
- claude-code
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
position_column: todo
position_ordinal: 8a80
title: 'Backend seam: makeSession(transcript:) transcript-seeded factory'
---
## What

The small, isolated factory seam session-tree restoration needs: create a backend from an existing `FoundationModels.Transcript` instead of from instructions. Split out of the restore task so it can land early and in parallel.

- Add to `LoadedLLMContainer` (Sources/FoundationModelsRouter/Resolution/ModelLoader.swift): `func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend`, alongside the existing `makeSession(instructions:)`.
- `MLXFoundationModelsContainer` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift) implements it via `LanguageModelSession(model:tools:transcript:)` — public API, and the identical call `MLXFoundationModelsSessionBackend.makeFork()` already makes. The backend's retained `instructions` are derived from the transcript's own `.instructions` entry when present (the entry is what carries them forward into generation; note this in a doc comment).
- Stub containers/`StubSessionBackend` (Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift) implement it by seeding the synthetic entries array from the given transcript's entries.

## Acceptance Criteria
- [ ] `LoadedLLMContainer.makeSession(transcript:)` exists with doc comments
- [ ] The MLX container seeds a live `LanguageModelSession` from the given transcript
- [ ] Stub containers seed `StubSessionBackend` entries from the given transcript
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit: a stub backend made from a 4-entry transcript reports those 4 entries via `transcriptEntries()` before any new turn
- [ ] Gated integration (`FM_ROUTER_INTEGRATION_TESTS`): a live backend seeded from a prior session's transcript answers a recall question about content from that transcript

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.