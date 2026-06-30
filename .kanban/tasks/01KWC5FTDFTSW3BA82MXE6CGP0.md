---
comments:
- actor: wballard
  id: 01kwd753yg3cf6gabw25b6bq7t
  text: 'Picked up milestone 5a. Read current APIs: Router.resolve/buildProfile (Router.swift), RoutedModel/RoutedLLM/RoutedEmbedder + LanguageModelProfile (LanguageModelProfile.swift), ModelLoader + LoadedEmbeddingContainer (ModelLoader.swift), TranscriptRecorder/Partial/InMemoryRecorder/JSONLRecorder (Recording/). MLXEmbedders EmbedderModelContainer has no sync dimension and only async perform() — real embed+dimension is genuinely milestone 7 GPU work, so the live conformance is a documented deferred seam (dimension 0 sentinel, embed throws) while the unit suite drives stubs. Design: eviction via new ModelLoader.evict (default no-op, stub overrides with spy); one-active-profile tracked on Router via residentProfileID + resolutionInFlight gate; LanguageModelProfile gains private router ref + release() (async, routes to Router.release) + deinit fire-and-forget; embed lives in new RoutedEmbedder.swift extension computing dimension from container and recording exactly one .embedding event best-effort. Writing failing tests first.'
  timestamp: 2026-06-30T21:32:23.376874+00:00
- actor: wballard
  id: 01kwd7ryz7ycn8vqewnhrabbx9
  text: 'Double-check (advisory) returned REVISE. Finding 1 (medium, real): residency was keyed on ObjectIdentifier, which is only unique among simultaneously-live objects — after a released profile deallocates, the allocator can reuse its address for the next profile, so the dead profile''s deinit-scheduled release could match and clobber the NEW profile''s residency (breaking one-active-profile + leaking the new profile''s containers). Fix: mint a monotonic, never-reused residency token (ULID) at resolve, store it on the profile, and match on it in Router.release. Removes ObjectIdentifier entirely (also resolves the self-in-deinit subtlety). Finding 2 (nit): deinit doc said "detached task" but uses an unstructured Task — wording corrected. The address-reuse bug can''t be reproduced deterministically in a unit test (allocator-dependent), so adding a deterministic test of the token-matching invariant: a release carrying a stale token must be a no-op against a newer resident profile.'
  timestamp: 2026-06-30T21:43:13.639601+00:00
- actor: wballard
  id: 01kwd83prdxmd3hm2s8p6h71dm
  text: 'Fix landed and re-verified. Residency now keyed on a unique, never-reused ULID token minted at resolve and stored on the profile; Router.release(token:containers:) matches on it, so a stale deinit after a newer profile is resolved is a guaranteed no-op (closes the ObjectIdentifier address-reuse hole). Removed ObjectIdentifier entirely; deinit captures only Sendable values (router, token, containers). Added deterministic test staleReleaseDoesNotClobberResident. Corrected doc wording ("monotonic" -> "unique", and "detached" -> "unstructured" task). Advisory double-check re-run: PASS (address-reuse closed; no regressions; new test exercises the token-mismatch no-op path, not vacuous). Verification: swift build clean (no warnings/errors); swift test green — 61 tests in 11 suites + 1 gated integration suite. Leaving task in doing for /review.'
  timestamp: 2026-06-30T21:49:05.677854+00:00
- actor: wballard
  id: 01kwd8z88d8w9k992gh4vadxvv
  text: Resolved both review findings in Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift. Added `///` doc comments to the UnconfiguredModelLoader sentinel members noting each always throws ModelLoaderError.notConfigured (real loading configured/injected via LiveModelLoader, milestone 7). Documented loadLLM and preload per the findings, plus loadEmbedder for consistency (was also undocumented) to avoid a follow-up finding. Doc-only change, no behavior change. swift build green; swift test green (61 tests pass + gated integration suite skips as expected). Ticked Acceptance Criteria and Tests checkboxes (work satisfies them and tests pass). Task left in doing for review.
  timestamp: 2026-06-30T22:04:08.333033+00:00
depends_on:
- 01KWC5F41MNA2PA3K45Z86CRQ0
- 01KWC5ECCZYEAH49J635KC9QH5
position_column: done
position_ordinal: 8b80
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
- [x] `release()` evicts all three (assert via an eviction spy/counter); after release, residency is clear.
- [x] Calling `resolve` a second time while a profile is resident throws (one-active-profile); it succeeds after `release()`.
- [x] `embed` returns vectors of length `dimension` (real vectors asserted in the gated integration suite; unit test uses a stub embedder).
- [x] `embed` emits exactly one `embedding` event with correct provenance to an `InMemoryRecorder`; a forced sink failure is swallowed and `embed` still returns.

## Tests
- [x] `Tests/FoundationModelsRouterTests/ProfileLifecycleTests.swift` (Swift Testing) with a stub embedder/loader + `InMemoryRecorder`: evict-all on release; one-active-profile enforcement (second resolve throws, then succeeds after release); embed records one `embedding` event + swallowed sink error.
- [x] Run `swift test --filter ProfileLifecycleTests` — all pass.

## Workflow
- Use `/tdd` — write failing evict / one-active-profile / embed-recording tests with stubs first.

## Review Findings (2026-06-30 16:50)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:150` — Public function `loadLLM` lacks documentation. Even though it implements a protocol requirement, the concrete implementation throws an error rather than performing the documented behavior, which warrants explicit documentation of this deviation. Add a doc comment explaining that this sentinel implementation always throws `.notConfigured`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:167` — Public function `preload` lacks documentation. Even though it implements a protocol requirement, the concrete implementation throws an error rather than performing the documented behavior, which warrants explicit documentation of this deviation. Add a doc comment explaining that this sentinel implementation always throws `.notConfigured`.