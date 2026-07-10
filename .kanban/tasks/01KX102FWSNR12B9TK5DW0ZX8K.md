---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx6p27t9prxr0f7gyw4jtcbk
  text: |-
    Implemented via TDD.

    **New source file**: `Sources/FoundationModelsRouter/Recording/TranscriptReconstruction.swift`
    - `TranscriptReconstructionError` (typed, `LocalizedError`): `legacyEventMissingPayload(session:seq:)`, `contentRemoved(session:seq:)`, `unregisteredCustomSegmentType(session:seq:discriminator:)`, plus `entryReconstructionFailed(session:seq:underlying:)` for any other mapper error (missingRequiredField/invalidJSON), so every reconstruction failure carries session+seq context.
    - `TranscriptTree.effectiveTranscript(forSession:registry:) throws -> Transcript` — maps `effectiveEntryEvents(forSession:)` through `TranscriptEntryMapper.entry(from:kind:registry:)`, wraps mapper errors with session/seq, and returns `Transcript(entries:)`.
    - Private `isFailedTurnBodylessClose(_:)` recognizes and skips the router-only bodyless `.response` close a failed turn's throw path emits (`entry == nil`, `text == nil`, `ms != nil`), with a long doc comment walking through why the shape is unambiguous vs. a genuine v1 legacy line (v1's bracket wrote `.prompt` unconditionally before ever calling the backend, so a bare orphan `.response` can never be genuine v1 — verified against git history at 06f8d16/889ab6a).

    **New tests**: `Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift` (9 unit tests) + `Tests/FoundationModelsRouterIntegrationTests/TranscriptReconstructionIntegrationTests.swift` (1 gated test behind `FM_ROUTER_INTEGRATION_TESTS`, compiles, not run here — no GPU/network in this environment). Covers: root round-trip vs. stub backend entries, 3-level fork tree effective-transcript-per-node, registered vs. unregistered custom segment, metadataOnly `contentRemoved` error, v1-legacy `missingPayload` error, failed-turn bodyless close skip, non-refusal mapper error wrapping, and two regression tests pinning down the v1-vs-synthetic-close disambiguation (a v1 prompt+response pair throws on the prompt; a v2 first-turn-total-failure with zero backend entries reconstructs to an empty Transcript).

    **Process note**: went through two rounds of adversarial double-check via the `really-done` skill. Round 1 found a real ambiguity in the bodyless-close skip heuristic (a genuine v1 `.response` recorded at `metadataOnly` decodes identically to the v2 synthetic close) plus uncontextualized mapper errors — both fixed. Round 2's re-check found my first fix's reasoning had a hole (didn't account for a v2 session whose very first turn fails before the backend appends anything at all) — fixed with a corrected two-part argument, backed by a new regression test and doc comment, and confirmed via git history that v1's bracket always wrote `.prompt` unconditionally (so the ambiguous shape can never arise from genuine v1). Round 3 re-check: PASS, with the reviewer independently re-deriving the argument from source rather than trusting the summary, and also checking a third scenario (a later turn failing after an earlier turn succeeded) that wasn't explicitly walked through in the docs — confirmed also safe.

    Verification (fresh, this session): `swift build --build-tests` exit 0. `swift test`: 294 tests in 33 suites pass, 12 gated integration tests correctly skipped (no `FM_ROUTER_INTEGRATION_TESTS`), 0 failures. `mcp__sah__diagnostics check working`: 0 errors, 0 warnings.

    Leaving in `doing` for `/review` per the implement skill workflow.
  timestamp: 2026-07-10T18:53:58.473009+00:00
depends_on:
- 01KX0ZZQF8ZHY6R2867RQ92KSK
- 01KX101V8CMHHS06NE3P7NQJXZ
- 01KX101CBDCFV4EQSPQT0BNK8R
position_column: doing
position_ordinal: '80'
title: Reconstruct FoundationModels.Transcript from recorded events
---
## What

The data-level payoff: turn what's on disk back into a real, SDK-native `Transcript`. Extend `TranscriptTree` (Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, or a sibling TranscriptReconstruction.swift if it reads better):

- `func effectiveTranscript(forSession id: ULID, registry: CustomSegmentRegistry = CustomSegmentRegistry()) throws -> FoundationModels.Transcript` — maps `effectiveEntryEvents(forSession:)` through `TranscriptEntryMapper.entry(from:kind:registry:)` and returns `Transcript(entries:)` (public initializer, verified in the macOS 27 swiftinterface). The `registry` parameter is how integrators get their concrete `PersistableCustomSegment` types rebuilt: callers with custom segments in their recordings register those types before reconstructing (see the mapper task and plan.md "Honest fidelity scope").
- Error contract (typed, descriptive — matching plan.md "Honest fidelity scope"): reconstruction requires `full`-level recordings. Three distinguishable refusals, each naming the session and seq: an entry-kind event with `entry == nil` (v1 legacy line), a payload with `contentRemoved == true` (metadataOnly-stripped — shape survives on disk for GUIs, but reconstruction must refuse it rather than silently rebuilding empty entries), and a custom-segment payload whose `typeDiscriminator` is not in the supplied registry (surfaced from the mapper, naming the discriminator). The bodyless `response` close from a failed turn (no `entry`, `ms` set, emitted by the chokepoint's throw path) must be recognized and skipped deliberately — it mirrors no SDK entry — with a doc comment explaining why it is skipped rather than an error.
- Doc comments state the fidelity scope: lossless for text/structured/tool content recorded at `full`; custom segments round-trip via the `CustomSegmentRegistry` (solved, not lossy — an unregistered discriminator is a typed error, never a silent drop); `sampling`, `metadata` dictionaries, URL-less attachments, and attachment bytes degrade as documented in the mapper.

## Acceptance Criteria
- [ ] `effectiveTranscript(forSession:registry:)` returns a `Transcript` whose entries equal the originals (kind sequence, segment content, ids) for stub-fabricated recordings
- [ ] A fork's effective transcript equals parent-history-at-fork + its own turns
- [ ] A recording containing a custom segment reconstructs a real `.custom` segment when its type is registered; the same recording with an empty registry throws the unregistered-discriminator error
- [ ] metadataOnly recordings (contentRemoved payloads) and v1 legacy lines produce their distinct documented typed errors; failed-turn closes are skipped by design
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] Unit in Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift (or new file): record stub turns, reconstruct, compare `Transcript` entries against the stub backend's own `transcriptEntries()` — equal count, kinds, and text content
- [ ] Unit: 3-level fork tree — each node's reconstructed effective transcript matches that node's backend entries at end of test
- [ ] Unit: a recording with a test-only `PersistableCustomSegment` entry reconstructs the real segment with the type registered, and throws the discriminator-naming error with an empty registry
- [ ] Unit: reconstruction over a metadataOnly recording throws the contentRemoved error; a fabricated v1 line throws the missing-payload error
- [ ] Unit: a recording containing a failed-turn bodyless close reconstructs successfully without it
- [ ] Gated integration (`FM_ROUTER_INTEGRATION_TESTS`): one live turn recorded at `full`, reconstructed `Transcript` entry kinds/count match the live `session.transcript`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.