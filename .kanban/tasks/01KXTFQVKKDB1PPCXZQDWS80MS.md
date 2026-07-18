---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'Spike: synthesized Transcript.Entry round-trip + native condensing check'
---
## What
De-risk the core compaction mechanism (compaction_plan.md §1.1, §6.1): prove that *synthesized* `Transcript.Entry` values — a summary entry we fabricate ourselves, and elision-placeholder entries replacing old `toolOutput` payloads — survive (a) being fed into a rebuilt `LanguageModelSession(transcript:)` and (b) the recording mirror (`Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift` → `TranscriptEntryPayload.swift` → reconstruction in `TranscriptReconstruction.swift`).

Also confirm whether WWDC26 FoundationModels ships any native transcript condensing/compaction API we should defer to instead of building our own — record the finding in the spike test file's header comment.

Deliverable is a test file `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift` (hermetic mirror round-trip) plus a gated live-session case in `Tests/FoundationModelsRouterIntegrationTests/` (`FM_ROUTER_INTEGRATION_TESTS`), and a short findings note appended to compaction_plan.md §6.1 (native-condensing verdict, any entry-synthesis gotchas such as non-settable `Transcript.Entry.id`).

## Acceptance Criteria
- [ ] A hermetic test synthesizes a summary `Transcript.Entry` (text segment) and an elision-placeholder entry, records both through the mirror, reconstructs, and gets identical structure back
- [ ] A gated integration test rebuilds a live `LanguageModelSession` over a transcript containing the synthesized entries and completes one turn without error
- [ ] Written verdict on whether entry ids of synthesized entries are stable/controllable (the `CompactionSegment` design in §1.2 depends on referencing `Transcript.Entry.id`s)
- [ ] Written verdict on WWDC26 native condensing (defer or build), noted in compaction_plan.md

## Tests
- [ ] `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift` — mirror round-trip of synthesized entries; `swift test --filter CompactionSpikeTests` passes
- [ ] Gated live round-trip case in `Tests/FoundationModelsRouterIntegrationTests/`; passes with `FM_ROUTER_INTEGRATION_TESTS=1`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction