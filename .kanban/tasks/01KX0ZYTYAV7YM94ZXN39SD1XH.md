---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Expose real Transcript state through LanguageModelSessionBackend
---
## What

Widen the backend seam so the router can observe the SDK's real conversation state. Today `LanguageModelSessionBackend` (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift) only returns `String` responses; only the concrete `MLXFoundationModelsSessionBackend` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift) can see `liveSession.transcript`, via a test-only `internal var session` accessor. This is the foundation for snapshot-diff persistence (see plan.md "Transcript fidelity" section).

- Add to the protocol: `func transcriptEntries() -> [FoundationModels.Transcript.Entry]` — the backend's current full transcript, in order. Doc comment must state it is only safe to call while holding the model's serial gate (`RoutedModel.serialGate`), same discipline as `makeFork()`.
- Implement in `MLXFoundationModelsSessionBackend`: return `Array(liveSession.transcript)`.
- Update `StubSessionBackend` (Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift) to maintain a synthetic `[Transcript.Entry]`: when constructed with non-nil instructions, seed one `.instructions` entry as the first entry (`Transcript.Instructions(segments:toolDefinitions:)` with one `TextSegment` carrying the instructions text and empty tool definitions) — mirroring `MLXFoundationModelsSessionBackend`/`LanguageModelSession`, where supplied instructions become the transcript's first entry; downstream tasks' tests (session index, chokepoint) rely on the stub modeling instructed sessions. Then on each `respond`/`streamResponse` call append a `.prompt` entry (one `TextSegment` with the prompt) and a `.response` entry (one `TextSegment` with the canned response), built with the SDK's public initializers (`Transcript.Prompt(segments:)`, `Transcript.Response(assetIDs:segments:)` — all verified public in the macOS 27 swiftinterface). `makeFork()` copies the current entries array into the child (models the fork-copies-parent-transcript semantics of `LanguageModelSession(model:tools:transcript:)`).
- Update any other inline test conformers of `LanguageModelSessionBackend` that now fail to compile.

## Acceptance Criteria
- [ ] `LanguageModelSessionBackend.transcriptEntries()` exists with a doc comment naming the serial-gate precondition
- [ ] `MLXFoundationModelsSessionBackend.transcriptEntries()` returns the live session's entries
- [ ] `StubSessionBackend` seeds a leading `.instructions` entry when constructed with non-nil instructions (none when nil), accumulates synthetic prompt/response entries per turn, and `makeFork()` snapshots them into the child
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit (Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift or Helpers tests): after two respond calls on an *uninstructed* stub, `transcriptEntries()` has 4 entries in prompt/response/prompt/response order
- [ ] Unit: an *instructed* stub's `transcriptEntries()` starts with exactly one `.instructions` entry, followed by prompt/response pairs (5 entries after two turns)
- [ ] Unit: a fork taken after turn 1 has exactly the parent's entries at fork time; parent's turn 2 does not appear in the child
- [ ] Gated integration (Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift, `FM_ROUTER_INTEGRATION_TESTS`): `transcriptEntries().count` equals `session.transcript.count` and grows across turns

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.