---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx69mhefz2mtpv2hgm56gy5b
  text: |-
    Implemented via TDD.

    RED: added the unit test (TranscriptSeededSessionTests in Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift) and the gated integration test (makeSessionFromTranscriptRecallsPriorContent in Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift) first, calling `container.makeSession(transcript:)` through `any LoadedLLMContainer` / the concrete MLX container. Confirmed compile failure for the right reason: "incorrect argument label in call (have 'transcript:', expected 'instructions:')" — the protocol had no such member yet.

    GREEN — implementation:
    - Sources/FoundationModelsRouter/Resolution/ModelLoader.swift: added `func makeSession(transcript: FoundationModels.Transcript) -> any LanguageModelSessionBackend` to `LoadedLLMContainer` with full doc comments (+ `import FoundationModels`).
    - Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift: `MLXFoundationModelsContainer.makeSession(transcript:)` builds a real `LanguageModelSession(model:tools:transcript:)` (the same initializer `MLXFoundationModelsSessionBackend.makeFork()` already uses) and derives the backend's retained `instructions` from the transcript's leading `.instructions` entry via a new private static `leadingInstructionsText(of:)` helper.
    - Every existing test-only `LoadedLLMContainer` conformer (~15 stub containers across 13 test files) got a matching `makeSession(transcript:) { StubSessionBackend(entries: Array(transcript)) }`, plus `import FoundationModels` added where missing — this is what "Stub containers/StubSessionBackend implement it by seeding the synthetic entries array" meant in practice: every stub container seeds a StubSessionBackend straight from the given transcript's entries.

    Tests added:
    - Unit: `TranscriptSeededSessionTests.stubBackendReportsSeededTranscriptEntriesBeforeAnyNewTurn` — a 4-entry transcript in, `transcriptEntries()` reports those same 4 entries before any new turn. Passes (`swift test --filter TranscriptSeededSessionTests`).
    - Gated integration (FM_ROUTER_INTEGRATION_TESTS): `makeSessionFromTranscriptRecallsPriorContent` — a live backend seeded via `container.makeSession(transcript:)` from a prior backend's `session.transcript` (built via `makeSession(instructions:)`, not `makeFork()`) answers a recall question about content from that transcript. Correctly gated/skipped in the default run.

    Verification: `swift build --build-tests` exits 0; `swift test` — 274/274 unit tests pass, gated suites correctly report 11 tests skipped. `mcp__sah__diagnostics check working` reports 0 errors/0 warnings. Spawned the `double-check` adversarial reviewer per the really-done workflow; awaiting its verdict before final handoff.

    Not wired into any production call site (RoutedModel/RoutedSession/LanguageModelProfile) — by design, per the task's "split out of the restore task so it can land early and in parallel" framing. That wiring is the separate restore task.
  timestamp: 2026-07-10T15:16:46.671298+00:00
- actor: claude-code
  id: 01kx69pv5at0h7hd3e548t0jnh
  text: |-
    Adversarial double-check verdict: PASS. Independently confirmed the protocol/MLX implementation, the 15 stub-container additions (no conflicts), that the gated integration test genuinely calls `container.makeSession(transcript:)` (not `makeFork()`, avoiding the "proves nothing new" trap), a clean `swift build --build-tests` + `swift test` run (274/274 unit tests, 11 integration tests correctly skipped), and that no production call site (RoutedModel/RoutedSession/LanguageModelProfile/Router) was touched — diff is purely additive (218 insertions, 4 deletions across 17 files).

    All acceptance criteria met:
    - [x] LoadedLLMContainer.makeSession(transcript:) exists with doc comments
    - [x] MLX container seeds a live LanguageModelSession from the given transcript
    - [x] Stub containers seed StubSessionBackend entries from the given transcript
    - [x] swift build and swift test exit 0
    - [x] Unit test: 4-entry transcript -> transcriptEntries() reports those 4 entries before any new turn
    - [x] Gated integration test: live backend seeded from a prior session's transcript recalls prior content

    Leaving in `doing`, ready for `/review`.
  timestamp: 2026-07-10T15:18:02.154387+00:00
depends_on:
- 01KX0ZYTYAV7YM94ZXN39SD1XH
position_column: doing
position_ordinal: '80'
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