---
depends_on:
- 01KWC5F41MNA2PA3K45Z86CRQ0
- 01KWC5ECCZYEAH49J635KC9QH5
position_column: todo
position_ordinal: 8a80
title: Profile residency lifecycle + recorded embedding access (milestone 5a)
---
## What
Give a resolved profile a residency lifetime and a recorded embedding surface. Plan "Residency", "Access API" (embed), "Transcripts & recording" (`embedding` event kind). The session/generation surface is split into milestone 5b; forking is milestone 9; full nesting/manifest is milestone 10.

- `Sources/FoundationModelsRouter/LanguageModelProfile.swift` (lifecycle):
  - `func release()` evicts all three models; `deinit` also runs it.
  - Enforce **one active profile at a time** on the `Router`: resolving while another profile is resident fails rather than over-committing RAM (release first).
- `Sources/FoundationModelsRouter/RoutedEmbedder.swift`:
  - `let dimension: Int`; `func embed(_ texts: [String]) async throws -> [[Float]]` over the resident `MLXEmbedders` model.
  - **Recorded:** `RoutedEmbedder` carries `routerID: ULID` + a non-optional `TranscriptRecorder` (populated by the Router at resolve — see milestone 4b). `embed` emits one `embedding` `TranscriptEvent` (provenance `{routerId, slot: .embedding, model, seq, ts, tokensIn?, ms}`) into a directory under the router recordings root (e.g. `recordings/<routerID>/embeddings/transcript.jsonl`). Best-effort: a sink failure logs, never fails `embed`.

## Acceptance Criteria
- [ ] `release()` evicts all three (assert via an eviction spy/counter); after release, residency is clear.
- [ ] Calling `resolve` a second time while a profile is resident throws (one-active-profile); it succeeds after `release()`.
- [ ] `embed` returns vectors of length `dimension` (real vectors asserted in the gated integration suite; unit test uses a stub embedder).
- [ ] `embed` emits exactly one `embedding` event with correct provenance to an `InMemoryRecorder`; a forced sink failure is swallowed and `embed` still returns.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift` (Swift Testing) with a stub embedder/loader + `InMemoryRecorder`: evict-all on release; one-active-profile enforcement (second resolve throws, then succeeds after release); embed records one `embedding` event + swallowed sink error.
- [ ] Run `swift test --filter ProfileLifecycleTests` — all pass.

## Workflow
- Use `/tdd` — write failing evict / one-active-profile / embed-recording tests with stubs first.