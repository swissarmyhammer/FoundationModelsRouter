---
depends_on:
- 01KWC5YV6WWKW3AXF39E7MRM58
- 01KWC5HV9BBARA3HJA26MMV0YC
- 01KWC5H7Y7NVG4771FR9ZKW5M0
- 01KWC5JSV0GM6AM05C6TXGN0TS
position_column: todo
position_ordinal: '9380'
title: 'Capstone: example/usage unit tests as living API documentation'
---
## What
Per user request (2026-06-30): provide a set of unit tests that are clear, readable **samples of using the public API end-to-end** — a capstone that doubles as living documentation. Distinct from the gated milestone-7 integration suite (`txgn0ts`): these run **offline in the normal unit-test target** (no network/GPU, no download), so they stay green in CI and demonstrate the call patterns a real consumer writes.

- `Tests/FoundationModelsRouterTests/ExamplesTests.swift` (Swift Testing) — a small, heavily-commented suite where each `@Test` is a self-contained "how do I…" example. The body must read like REAL usage: define a `ProfileDefinition` (Swift-literal manifest, biggest/best first), construct a `Router`, `resolve` it, then use the resolved profile. Isolate the unit-test seam (injected stub `ModelLoader` + `MetadataSource` + `MachineProbe`, and an `InMemoryRecorder`) to ONE clearly-commented setup helper so the example bodies themselves look exactly like production code. Add a header doc comment pointing readers here as the canonical usage reference.
- Cover, as separate named examples (use whichever public APIs exist once dependencies are done):
  - Authoring a `ProfileDefinition` + resolving via `Router.resolve(_:reporting:)`, observing `ResolutionProgress` advance to `.ready`.
  - Generation: `profile.standard.makeSession(instructions:)` then `respond(to:)`; and `streamResponse(to:)` consuming the stream.
  - Embedding: `profile.embedding.embed([...])` and reading `dimension`.
  - Guided generation, all three shapes: typed `respond(to:generating:)`, dynamic-JSON `respond(to:matching:)`, and raw `respond(to:following:)` / `makeGuidedSession`.
  - Subagent fan-out: a guided/template session `fork()`ed N times (the plan's "many short-lived forks" pattern).
  - Residency lifecycle: `release()` and one-active-profile.
- Keep each example minimal and copy-pasteable; prefer clarity over coverage (correctness coverage lives in the per-feature suites). If a planned API shifts during implementation, this task updates the examples to match the final surface.

## Acceptance Criteria
- [ ] `Tests/FoundationModelsRouterTests/ExamplesTests.swift` exists with one clearly-named `@Test` per usage pattern above, each reading like real consumer code (stub wiring confined to a single commented setup helper).
- [ ] The suite runs in the NON-gated unit target — green under `swift test` with no network/GPU/download.
- [ ] Examples exercise the actual shipped public API (compile against the real types/signatures; no pseudo-code), covering resolve+progress, session respond + stream, embed, all three guided shapes, fork fan-out, and release/one-active-profile.
- [ ] A header doc comment designates this file as the canonical usage reference.

## Tests
- [ ] The suite IS the test. Run `swift test --filter ExamplesTests` (env `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`) — all pass; confirm full `swift test` stays green.

## Workflow
- Use `/tdd` — write each example as an executable assertion of the documented call pattern; if an API reads awkwardly in an example, that is a signal to flag (not to paper over).