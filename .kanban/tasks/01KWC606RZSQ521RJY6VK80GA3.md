---
comments:
- actor: wballard
  id: 01kwezhbbjwdgkds1yqas728m3
  text: |-
    Picked up (doing). Research done. Plan:
    - Milestone 10a events (TranscriptEvent/Partial) carry NO body text field yet, so `full` vs `metadataOnly` can't differ. Adding `text: String?` (default nil) to TranscriptEvent + Partial + stamped() is in scope; thread prompt/response text through RoutedSession.generate chokepoint and input text through RoutedEmbedder.embed.
    - Gating: new GatingRecorder decorator (Recording/GatingRecorder.swift) wraps any sink; off=drop, metadataOnly=nil the text (keep counts/kinds/provenance), full=keep text applying redact. Router.init wraps its base recorder via a `gated(...)` helper, but ONLY when it would change behavior (skip wrap for verbatim .full + nil redact) so the existing ResolveTests identity invariant (handle.recorder === passed InMemoryRecorder, default full/no-redact) stays green. All event sources honor it automatically since they already call recorder.append.
    - MergedTranscript.merged(under: routerDir): enumerate **/transcript.jsonl, decode, sort by (ts, seq) tuple → totally-ordered [TranscriptEvent].
    - Tests MergedAndRedactionTests.swift (Swift Testing, stub model/no GPU): merged (ts,seq) total order under concurrent appends across session dirs w/ fixed clock (ts ties -> seq tiebreak); GatingRecorder unit tests per level + redact; integration via Router+session+embed for metadataOnly/redact wiring; swallow-under-gating (JSONL pointed at a regular-file blocker => createDirectory throws, swallowed) proving respond+embed still succeed.
  timestamp: 2026-07-01T13:57:44.434910+00:00
- actor: wballard
  id: 01kwf08fjw644mnhrhmxsg3hk3
  text: |-
    Implementation landed, GREEN, left in `doing` for review.

    What was built:
    - Added `text: String?` body field to TranscriptEvent + Partial (threaded through stamped()) plus Partial.mapText helper — 10a events had no body, so full vs metadataOnly could not differ; adding it was required and in scope.
    - New Recording/GatingRecorder.swift: decorator enforcing RecordingLevel + redact. off=drop (no forward, no file), metadataOnly=mapText->nil (keeps counts/kinds/provenance), full=forward (applying redact to body when set). Best-effort preserved: it only reshapes/drops the partial; the inner sink still owns seq/ts and the non-throwing swallow.
    - New Recording/MergedTranscript.swift: `merged(under: routerDirectory)` enumerates **/transcript.jsonl, decodes every line, returns events sorted by the (ts, seq) tuple — the totally-ordered whole-router stream.
    - Router wires gating via Self.gated(base, level, redact); wraps ONLY when level != .full || redact != nil, so verbatim full+no-redact keeps the raw recorder identity and the existing ResolveTests `recorder === passed` invariant stays green. All event sources honor gating automatically because they already append through the router's recorder.
    - RoutedSession.generate now takes prompt and records prompt text on .prompt and response text on .response (streaming accumulates chunks; error path close event is deliberately bodyless). RoutedEmbedder.embed records joined input as the .embedding body — gated identically. Stale "milestone 10b" docs updated.

    Tests: Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift (Swift Testing, stub model, no GPU) — 9 tests: merged (ts,seq) total order under concurrent appends across 4 session dirs with a fixed clock (ts ties -> seq must break them); off writes nothing / no jsonl file; metadataOnly omits body keeps counts+kinds; full verbatim; redact transforms; metadataOnly + redact wired end-to-end through Router across session turns AND embeddings; swallow-under-gating (recordingsDir = regular-file blocker -> createDirectory throws, swallowed) with respond+embed still returning.

    Verification (DEVELOPER_DIR=Xcode-beta): `swift build` clean; `swift test --filter MergedAndRedactionTests` 9/9; full `swift test` 110/110 + gated suite skipped as designed; no warnings.

    Adversarial double-check: PASS, no defects. Advisory (not a defect, logged per contract): the merged test's fixed clock means a comparator that dropped the ts primary key (pure seq) would still pass; harmless given the single-recorder single-seq-space design, would only matter if a future merge served independent seq spaces.

    Ready for /review.
  timestamp: 2026-07-01T14:10:22.428169+00:00
- actor: wballard
  id: 01kwf1f8w86h364erb23z7j6y6
  text: |-
    Resolved all 5 review findings (2026-07-01 09:11 batch):

    1. RoutedEmbedder.embed — added explicit `to: nil` label on `recorder.append(...)`, matching the RoutedSession call-site convention. The label-less overload forwarded to `to: nil` anyway, so behavior is identical.
    2. Router.resolve finalize — CLEAN LOOP achieved (no casts). `finalize` already takes the common `any LoadedModelContainer` base, and both `LoadedLLMContainer`/`LoadedEmbeddingContainer` refine it, so `[(ModelSlot, any LoadedModelContainer)]` upcasts implicitly. Replaced the three calls with a loop over that pair list in the same standard→flash→embedding order. No heterogeneous `as` casts were needed — the prior pass's cast concern didn't apply because finalize's parameter is already the base type.
    3. Router.init — inlined the single-call-site `gated(...)` helper as an if/else on `self.recorder` (base when `.full && redact == nil`, else GatingRecorder), preserved the "why" doc as an inline comment, and deleted the static helper.
    4. Router.slotResolution — replaced `.first { }!` force-unwrap with `guard let ... first(where:) else { preconditionFailure(...) }`; documents the total-by-construction invariant, traps identically to `!`.
    5. MergedAndRedactionTests.mergedTotalOrderAcrossConcurrentSessions — added `#expect(merged.allSatisfy { $0.text == "body" })` asserting the body survives the JSONL round-trip, not just seq order.

    Full `swift test` green: 110 tests / 18 suites pass, plus the gated integration suite (1 skipped as expected). No warnings.
  timestamp: 2026-07-01T14:31:33.512293+00:00
depends_on:
- 01KWC5J8K8C0E2ENKB33V4R8SH
position_column: doing
position_ordinal: '80'
title: 'Transcripts: merged-view helper + redaction/level gating (milestone 10b)'
---
## What
The two cross-cutting recording features layered on the core nesting/events (milestone 10a). Plan "Transcripts & recording".

- `Sources/FoundationModelsRouter/Recording/MergedTranscript.swift`:
  - A helper that merges `**/transcript.jsonl` under `recordings/<routerID>/` by `(ts, seq)` into the "what did this whole Router do" view (ULID-ordered paths already give near-order); returns the totally-ordered event stream.
- `Sources/FoundationModelsRouter/Recording/` (gating):
  - Enforce the `RecordingLevel` (`off` / `metadataOnly` / `full`) and the `redact` hook configured on `Router.init` (the seam added in milestone 4b). `off` writes nothing; `metadataOnly` omits prompt/response bodies but keeps counts (`tokensIn/Out`, `ms`, kinds); `full` writes bodies; the `redact` closure transforms recorded text before it is written (local models still see sensitive prompts).
  - Wire the level/hook through the recorder sinks so all event sources (sessions + `RoutedEmbedder.embed`) honor them.

## Acceptance Criteria
- [ ] The merged view across multiple sessions/forks is totally ordered by `(ts, seq)` even with concurrent generation.
- [ ] Level `off` writes nothing; `metadataOnly` omits bodies but keeps counts/kinds; `full` writes bodies.
- [ ] The `redact` hook transforms recorded prompt/response text before it is written.
- [ ] A forced sink write failure logs but generation/embedding still succeeds (best-effort preserved under gating).

## Tests
- [ ] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift` (Swift Testing) with `.jsonl` temp dir + `.inMemory`: merged `(ts, seq)` total order under concurrent appends across sessions; each level's body/count behavior; redaction transform applied; swallowed write error.
- [ ] Run `swift test --filter MergedAndRedactionTests` — all pass.

## Workflow
- Use `/tdd` — write failing merge-ordering, level-gating, and redaction tests first.

## Review Findings (2026-07-01 09:11)

- [x] `Sources/FoundationModelsRouter/RoutedEmbedder.swift:33` — The `recorder.append` call is missing the explicit `to:` parameter label that is required by the signature, unlike the pattern used in RoutedSession. Add explicit `to:` parameter: `await recorder.append(..., to: nil)` or pass the appropriate directory if available.
- [x] `Sources/FoundationModelsRouter/Router.swift:183` — Three identical finalize calls for .standard, .flash, and .embedding slots should be consolidated into a loop. Parallel code paths that differ only in constants (slot and container parameters) should instead be a single code path interpreting data, consistent with the download section's loop pattern earlier in the method. Replace the three separate finalize calls with a loop: `let finalizePairs: [(ModelSlot, any LoadedModelContainer)] = [(.standard, standardContainer), (.flash, flashContainer), (.embedding, embeddingContainer)]; for (slot, container) in finalizePairs { try await finalize(slot, container: container, progress: progress) }`.
- [x] `Sources/FoundationModelsRouter/Router.swift:280` — Needless helper with single call site. The `gated` method wraps the router's recorder in a GatingRecorder when needed, but is called only once from the init method. The conditional logic (`if level == .full && redact == nil { return base } else { return GatingRecorder(...) }`) is straightforward enough to inline without loss of clarity. Inline the gating logic directly in the Router.init method where `self.recorder` is assigned (around line 135). Replace the call `Self.gated(baseRecorder, level: recordingLevel, redact: redact)` with the conditional expression inline.
- [x] `Sources/FoundationModelsRouter/Router.swift:596` — Force unwrap `!` on `first { }` result violates the no-force-unwrap rule in non-test code, even though the comment explains it is safe by construction. Replace with proper error handling: guard or fatalError/preconditionFailure only if truly unreachable, or redesign to return Optional and let caller handle.
- [x] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift:49` — The test `mergedTotalOrderAcrossConcurrentSessions` writes TranscriptEvent.Partial objects with `text: "body"` to JSONLRecorder and then reads them back through MergedTranscript.merged(), but only verifies the seq ordering is preserved — it does not verify that the text field is correctly decoded and preserved in the round-trip. With the new text field on TranscriptEvent and the new MergedTranscript.merged() read operation, a round-trip test should verify both directions work together, especially since GatingRecorder will modify or drop text during writing. Add an assertion after line 72 to verify the text field is preserved: `#expect(merged.allSatisfy { $0.text == "body" })` to confirm the round-trip encoding/decoding of text works correctly.