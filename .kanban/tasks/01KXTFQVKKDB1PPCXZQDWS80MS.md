---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky7my0cymaq65waj1q0vgspj
  text: |-
    Research done. Read TranscriptEntryMapper.swift, TranscriptEntryPayload.swift, TranscriptReconstruction.swift, CustomSegmentRegistry.swift, RoutedSession.swift, and compaction_plan.md. Studied existing test patterns (TranscriptFidelityTests, TranscriptReconstructionTests, TranscriptReconstructionIntegrationTests, SessionTreeRestorationIntegrationTests) for the stub-backend and gated-integration-harness conventions to follow.

    Native condensing check: grepped the installed macOS 27 Xcode-beta SDK's FoundationModels.framework public interface (arm64e-apple-macos.swiftinterface) for compact|condens|summar|trim|prune|fold|truncat — zero matches anywhere in the framework. Only context-window-related surface is LanguageModelSession.contextSize (read-only Int) and LanguageModelError.contextSizeExceeded / deprecated GenerationError.exceededContextWindowSize. Verdict: BUILD, not defer — compaction_plan.md's from-scratch design is the only option.

    Entry-id check: same .swiftinterface confirms every Transcript.Entry case's id is a settable `var String`, supplied at construction (defaulted to UUID().uuidString for instructions/prompt/response/reasoning; required with no default for toolCalls/toolOutput) — so ids are fully controllable at synthesis time, including deliberately reusing an old entry's id for an elision placeholder.

    Wrote Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift (hermetic): two direct TranscriptEntryMapper round-trip tests (synthesized summary .response entry; synthesized elision-placeholder .toolOutput entry reusing an old entry's id) plus one full-pipeline test that drives a real RoutedSession turn with a stub backend whose "SDK transcript" is exactly a synthesized [instructions, toolCalls, elision-placeholder toolOutput, summary response] array, persists it through the real JSONLRecorder, and reconstructs via TranscriptTree.effectiveTranscript(forSession:) — asserting identical structure and ids back. All 3 tests passed on first run with zero production-code changes needed: the existing mapper/reconstruction machinery already handles synthesized (non-SDK-produced) entries generically, including id reuse. This is the expected/correct spike outcome — proving the mechanism already works, not a gap to fix.

    Wrote Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift (gated, FM_ROUTER_INTEGRATION_TESTS): builds a real MLXFoundationModelsContainer via LiveModelLoader, constructs a Transcript containing the same synthesized shape (instructions, toolCalls, elision-placeholder toolOutput, synthesized summary response) with hand-picked ids, calls container.makeSession(transcript:) directly (the exact factory a compact()/restore rebuild would use), and drives one real turn — asserting it completes without error, the model actually recalls a fact planted only in the synthesized summary entry, and the synthesized ids are still present unchanged both immediately after ingest and after the turn. Both new test files build cleanly (`swift build --build-tests` green). About to attempt actually running the gated suite (model is already cached locally: mlx-community/Qwen3.6-27B-mxfp4) to get the empirical answer for whether LanguageModelSession(transcript:) preserves or reassigns synthesized entry ids on ingest.
  timestamp: 2026-07-23T14:09:07.486749+00:00
- actor: claude-code
  id: 01ky7nhm8p2vjdggv5p0z0xe8m
  text: |-
    Attempted to actually run the gated integration suite (model already cached locally: mlx-community/Qwen3.6-27B-mxfp4): `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter CompactionSpikeIntegrationTests` fails at model-load time with "MLX error: Failed to load the default metallib. library not found ...". Reproduced the identical failure against the pre-existing, previously-verified-working `TranscriptReconstructionIntegrationTests` suite (unrelated to this task's changes) — confirms this is a pre-existing environment limitation of this sandbox (CI has a dedicated metallib-copy step per .github/workflows/ci.yml's `integration-metallib-glob` input; that step doesn't run when invoking `swift test` directly here). Tried copying the nested Cmlx bundle's default.metallib to the xctest bundle root as a workaround; did not resolve it (traced mlx-swift's device.cpp search order: colocated binary dir, then NSBundle.mainBundle()/allBundles() lookup for a SwiftPM resource bundle — the latter should find the already-present nested bundle, but does not in this sandbox's `swift test` invocation). Did not spend further time on this — it is orthogonal to the spike's actual deliverable (the mapper/reconstruction mechanism and the SDK API surface), which is fully verified via the static SDK-interface check and the passing hermetic suite.

    Ran the adversarial double-check agent per really-done. Verdict: REVISE (minor). Finding 1: the direct-mapper elision-placeholder test is mechanically identical to existing TranscriptEntryMapperTests.toolOutputRoundTrips() at the single-entry level — id "reuse" is only meaningfully exercised across entries in the full-pipeline test. Fixed by editing that test's doc comment and @Test name to stop overclaiming distinct coverage and point at the full-pipeline test as where reuse is actually proven; kept the test itself since it's still a fast, valid check of this specific shape. Finding 2: this comment/checklist gap itself — addressed now.

    Fresh verification after the doc fix: `swift build` green, `swift build --build-tests` green (only the known pre-existing mlx-swift_Cmlx.bundle warning), `swift test` — "Test run with 408 tests in 44 suites passed" (baseline 405/43 + this task's 3 new hermetic tests/1 new suite) plus "Test run with 16 tests in 6 suites passed" for the gated suite, all correctly skipped without the env var (baseline 15/5 + this task's 1 new gated test/1 new suite). Zero failures, zero unexpected warnings.

    Leaving in doing for /review. The gated integration test (Tests/FoundationModelsRouterIntegrationTests/CompactionSpikeIntegrationTests.swift) is written and compiles correctly but its "completes one turn without error" acceptance criterion has NOT been empirically verified passing, due to the sandbox limitation above — flagging this explicitly rather than checking that box.
  timestamp: 2026-07-23T14:19:50.422220+00:00
position_column: done
position_ordinal: c980
title: 'Spike: synthesized Transcript.Entry round-trip + native condensing check'
---
## What
De-risk the core compaction mechanism (compaction_plan.md §1.1, §6.1): prove that *synthesized* `Transcript.Entry` values — a summary entry we fabricate ourselves, and elision-placeholder entries replacing old `toolOutput` payloads — survive (a) being fed into a rebuilt `LanguageModelSession(transcript:)` and (b) the recording mirror (`Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift` → `TranscriptEntryPayload.swift` → reconstruction in `TranscriptReconstruction.swift`).

Also confirm whether WWDC26 FoundationModels ships any native transcript condensing/compaction API we should defer to instead of building our own — record the finding in the spike test file's header comment.

Deliverable is a test file `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift` (hermetic mirror round-trip) plus a gated live-session case in `Tests/FoundationModelsRouterIntegrationTests/` (`FM_ROUTER_INTEGRATION_TESTS`), and a short findings note appended to compaction_plan.md §6.1 (native-condensing verdict, any entry-synthesis gotchas such as non-settable `Transcript.Entry.id`).

## Acceptance Criteria
- [x] A hermetic test synthesizes a summary `Transcript.Entry` (text segment) and an elision-placeholder entry, records both through the mirror, reconstructs, and gets identical structure back
- [ ] A gated integration test rebuilds a live `LanguageModelSession` over a transcript containing the synthesized entries and completes one turn without error (written and compiles; NOT empirically verified passing — blocked by a pre-existing MLX metallib-load limitation in the authoring sandbox, reproduced against a pre-existing gated suite; see task comments)
- [x] Written verdict on whether entry ids of synthesized entries are stable/controllable (the `CompactionSegment` design in §1.2 depends on referencing `Transcript.Entry.id`s)
- [x] Written verdict on WWDC26 native condensing (defer or build), noted in compaction_plan.md

## Tests
- [x] `Tests/FoundationModelsRouterTests/CompactionSpikeTests.swift` — mirror round-trip of synthesized entries; `swift test --filter CompactionSpikeTests` passes
- [ ] Gated live round-trip case in `Tests/FoundationModelsRouterIntegrationTests/`; passes with `FM_ROUTER_INTEGRATION_TESTS=1` (written; not run to green in the authoring sandbox — see task comments)

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction

## Review Findings (2026-07-23 09:24)

Engine review of checkpoint delta `HEAD~1..HEAD` (commit 5858444cf26ccf5bad3ae01cdb5e4a981d1565cb): 0 findings (14 checks attempted, 0 confirmed, 0 refuted, 0 failed). Diff is clean.

Judgment call on the one unchecked acceptance-criteria item (gated integration test not run to green): accepted as-is. This is a spike/investigation task; the gap is a documented, pre-existing sandbox limitation (no GPU + missing CI metallib-copy step) reproduced identically against an unrelated, previously-working gated suite (`TranscriptReconstructionIntegrationTests`) — consistent with every other gated integration suite in this repo, which all skip without `FM_ROUTER_INTEGRATION_TESTS` + a real GPU. Not a new gap introduced by this diff, and not something further work in this sandbox can close. No new work invented beyond what the diff needed.