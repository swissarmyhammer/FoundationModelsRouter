---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx4ncd63sethfbacb6t6t6s4
  text: |-
    Implementation complete, following /tdd:

    - Added `func transcriptEntries() -> [FoundationModels.Transcript.Entry]` to `LanguageModelSessionBackend` (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift), with a doc comment naming the `RoutedModel.serialGate` precondition (same discipline as `makeFork()`).
    - Implemented in `MLXFoundationModelsSessionBackend` (Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift): `Array(liveSession.transcript)`.
    - Rewrote `StubSessionBackend` (Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift) to maintain a synthetic `entries: [Transcript.Entry]`: seeds one `.instructions` entry (via `Transcript.Instructions(segments:toolDefinitions:)`) when constructed with non-nil `instructions:`; each successful respond/streamResponse/guided-respond call appends a `.prompt` entry (`Transcript.Prompt(segments:)`) then a `.response` entry (`Transcript.Response(assetIDs:segments:)`) — response entry is skipped when the call throws (shouldThrow or grammar validation failure) so a failed turn doesn't fabricate a response. `makeFork()` now also snapshots `entries` into the child alongside `receivedPrompts`.
    - Updated 4 other inline test conformers of `LanguageModelSessionBackend` that needed a `transcriptEntries()` method to keep compiling: `TrackingBackend`/`ParkableSessionBackend` (MultiTurnSessionTests.swift), `MaxTokensRecordingBackend` (GuidedGenerationTests.swift and SessionChokepointTests.swift, one each), `TrackingSessionBackend` (ForkConcurrencyTests.swift). The ones wrapping a `StubSessionBackend` proxy to it; the two that don't (ParkableSessionBackend, TrackingSessionBackend) return `[]` since neither suite exercises transcript state.
    - Verified the FoundationModels v2 SDK's real public initializers against the macOS 27 swiftinterface at `/Applications/Xcode-beta.app/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` before using them (`Transcript.Instructions(id:segments:toolDefinitions:)`, `Transcript.Prompt(id:segments:options:responseFormat:...)`, `Transcript.Response(id:assetIDs:segments:)`, `Transcript.TextSegment(id:content:)`).

    Tests added:
    - Tests/FoundationModelsRouterTests/LanguageModelSessionBackendTests.swift: new `StubSessionBackendTranscriptTests` suite — uninstructed stub 4 entries (prompt/response/prompt/response) after two turns; instructed stub 5 entries starting with exactly one `.instructions`; uninstructed stub seeds no `.instructions` entry; fork snapshots parent's entries at fork time and the parent's later turn does not retroactively appear in the child.
    - Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift: gated (`FM_ROUTER_INTEGRATION_TESTS`) `transcriptEntriesMatchesSessionTranscriptAndGrows` — asserts `transcriptEntries().count == session.transcript.count` before any turn, after turn 1, and after turn 2 (with strict growth).

    TDD note: this is a protocol-widening change across ~7 files that must all move together to keep the target compiling, so a literal per-behavior red/green cycle for every file isn't possible (the code won't compile at all until the method exists everywhere). Did a red/green sanity check instead: temporarily reverted the `.instructions`-seeding branch in `StubSessionBackend.init`, reran the new suite, and watched `instructedStubSeedsLeadingInstructionsEntry` fail for the right reason (`entries.count` 4 not 5, wrong case at index 0) before restoring the fix.

    Verification: `swift build --build-tests` clean (rm -rf .build/out first) — exit 0, zero warnings in our code (only pre-existing vendored mlx-swift C++ warnings). `swift test` — 186/186 unit tests pass, 8/8 gated integration tests correctly skipped (no `FM_ROUTER_INTEGRATION_TESTS`/network/GPU here). Adversarial double-check agent dispatched for independent verification before handoff.
  timestamp: 2026-07-10T00:03:34.211842+00:00
- actor: claude-code
  id: 01kx4nh6gamfa5be0cn9fe10gk
  text: |-
    Adversarial double-check: PASS. Independently verified the diff, SDK API usage against the real macOS 27 swiftinterface, makeFork() value-semantics copy of `entries`, response-entry-skipped-on-throw logic, doc comment naming the serial-gate precondition, and conformer completeness (grepped all `: LanguageModelSessionBackend` declarations — all 6 non-StubSessionBackend conformers plus StubSessionBackend itself have `transcriptEntries()`). Independently reran `swift build --build-tests` (clean) and `swift test` (186/186 unit pass, 8 gated integration skip) — matches reported numbers exactly. Only note: my own earlier progress comment undercounted the inline conformers as "4" when it's actually 5 distinct classes across 4 files — a wording slip in the comment text only, not in the code. No action needed.

    Leaving task in `doing` per /implement workflow — ready for /review.
  timestamp: 2026-07-10T00:06:11.210669+00:00
position_column: doing
position_ordinal: '80'
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