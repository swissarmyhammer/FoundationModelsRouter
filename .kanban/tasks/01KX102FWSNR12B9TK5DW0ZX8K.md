---
assignees:
- claude-code
depends_on:
- 01KX0ZZQF8ZHY6R2867RQ92KSK
- 01KX101V8CMHHS06NE3P7NQJXZ
- 01KX101CBDCFV4EQSPQT0BNK8R
position_column: todo
position_ordinal: '8880'
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