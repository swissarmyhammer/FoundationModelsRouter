---
assignees:
- claude-code
depends_on:
- 01KXTFQVKKDB1PPCXZQDWS80MS
position_column: todo
position_ordinal: '8180'
title: CompactionSegment + default registry registration
---
## What
Create `Sources/FoundationModelsRouter/Compaction/CompactionSegment.swift` (new `Compaction/` directory): a `PersistableCustomSegment` whose `Codable` content is the fold metadata (compaction_plan.md §1.2):
- ordered live-window entry ids (the `Transcript.Entry.id`s constituting the compacted window)
- folded entry ids (what the window replaced)
- `tokensBefore`/`tokensAfter`, `stagesApplied: [String]`, and the compaction prompt `name`

**Default registration — name the mechanism and its blast radius.** `CustomSegmentRegistry()` (`Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift`) is empty by design, and every reconstruction entry point defaults to an empty registry that *throws* on any `.custom` segment: `effectiveTranscript(forSession:registry:)` in `TranscriptReconstruction.swift`, `restoreSessionTree(root:registry:)` in `SessionTreeRestoration.swift`, and `RoutedLLM.makeLanguageModel(resuming:)` in `RoutedLLM.swift`. Without changes there, the first compacted session would make every default-argument restore throw. Either introduce `CustomSegmentRegistry.routerDefault` (pre-seeded with `CompactionSegment`) and switch the defaulted `registry:` parameters at all three entry points to it, or pre-register in `init()` — and design around the duplicate-discriminator trap in `register` so a consumer re-registering `CompactionSegment` (or adding their own segments) doesn't trap. No schema work otherwise: the summary entry persists via the existing `SegmentPayload.custom` path in `TranscriptEntryPayload.swift`.

Honor the spike task's findings on entry-id stability (dws80ms).

## Acceptance Criteria
- [ ] `CompactionSegment` encodes/decodes all fold metadata fields losslessly
- [ ] A synthesized summary entry carrying a text segment + `CompactionSegment` round-trips through the recording mirror (record → `transcript.jsonl` payload → reconstruct) with metadata intact
- [ ] Restoring a transcript containing a `CompactionSegment` through `effectiveTranscript`, `restoreSessionTree`, and `makeLanguageModel(resuming:)` with all-default arguments succeeds — zero consumer configuration
- [ ] A consumer registering their own custom segments (or re-registering `CompactionSegment`) alongside the default does not trap

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CompactionSegmentTests.swift` — Codable round-trip, mirror round-trip via `TranscriptEntryMapper`/reconstruction, all-default-arguments restore of a segment-bearing transcript, duplicate/consumer registration; `swift test --filter CompactionSegmentTests` passes
- [ ] Existing reconstruction/restore test suites still pass unchanged (`swift test`)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction