---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzvbkbvj52wyz55cmnh439xq
  text: |-
    Research findings:
    - Group 1 can use ScriptedToolCallingContainer + the real MLXFoundationModelsSessionBackend. The generation channel has a `.reasoning(entryID:action:)` case, so the scripted executor can emit a `.reasoning` entry. A tool with a @Generable output type must give a `.structure` segment in its `.toolOutput` entry. Plan: extend ScriptedTurnScript with an optional `reasoning` field, add a structured-output marker tool, and add a durable (JSONLRecorder + recordingsDir) fixture path. RouterTestFixtures.makeRouter gets `id` and `recordingsDir` parameters with defaults, so old callers do not change.
    - Group 2: TranscriptEntryMapperTests.assertRoundTrips already does full `Transcript.Entry` equality. Plan: add a registry parameter to it, add mixed-segment and multi-call tests, and change the URL-attachment and registered-custom tests to full-entry equality (strictly stronger, no near-duplicate tests).
    - Group 3: after a fold, RoutedSessionActor swaps its backend with `backend.replacingTranscript(applied)`. The container does not see this swap, so a test cannot read the live post-fold transcript today. Plan: add an optional clone registry to StubSessionBackend (recorded at init, carried across makeFork/replacingTranscript). The last recorded backend after compact() is the live backend. Budget `TokenBudget(limit: recencyOnly * 2, target: 0.25)` forces the Summarization stage (see RoutedSessionCompactTests), with the stub backend as the scripted summarizer.
    - Group 4: ScriptedToolCallingModel composes its final answer from the `.toolOutput` entries in the transcript it is handed. A restored fork whose parent recorded a marker tool turn answers with that marker only when the inherited entries reach the restored live session. This makes the continuity claim exact and ungated.
    - Restore surface: `profile.standard.restoreSessionTree(root:)` (pattern in ForkAfterCompactionRestorationTests). `TranscriptTree.effectiveTranscript` defaults to registry `.routerDefault`, which contains CompactionSegment.
  timestamp: 2026-08-12T16:06:32.050946+00:00
- actor: claude-code
  id: 01kzvj2w14y83qp0vwzh34t0qf
  text: |-
    Implementation landed. All four groups run in the default ungated suite and pass. Real findings from TDD, and the adjustments made:

    1. **Raw live-vs-restored entry equality cannot hold for a tool turn.** Field-level dumps show three live-only facets that no persisted form keeps today:
       - A live tool call's `arguments` carry a `GenerationID` (its value is the call id). `GenerationID`'s only public constructor is `init()` (random) and it is not Codable, so no persisted form can rebuild it. This is an SDK limit, permanent.
       - A live `.structure` segment's `GeneratedContent` carries its property order; the mapper's `GeneratedContent(json:)` rebuild drops it. Fixable through `GeneratedContent(kind: .structure(properties:orderedKeys:))`.
       - A rebuilt `.response` synthesizes a `metadata["assetIDs"]` key a live generated response never carries. Fixable with a non-synthesizing initializer when persisted `assetIds` is empty.
       Filed follow-up task ^ja94kb6 (tags: transcript) for the two fixable mapper degradations. Group 1's test asserts full entry-array equality against the live transcript's record-time canonical form (`canonicalized(_:)` in RestoreFidelityTests documents all three facets), across all six entry kinds, with a multi-call `.toolCalls`, a `.structure` tool output, and a `.reasoning` entry — and the fold/restore group asserts raw entry-array equality (its stub-built entries carry none of the three facets).
    2. **Full entry equality is impossible for any attachment.** `Transcript.ImageAttachment`'s `==` compares the identity of the per-instance image buffer (VisionCore.ImageBuffer), so two attachments built from the same URL are never equal. The URL-attachment mapper test now compares every representable field (entry id, asset ids, segment count, attachment id, label, URL) and documents the limit; the mixed-segment full-equality test uses text + structure.

    Changes:
    - Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift (new): groups 1, 3, 4.
    - Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift: registry-aware assertRoundTrips; new mixed-segment and multi-call full-equality tests; registered-custom test raised to full entry equality; URL-attachment test raised to every representable field.
    - Helpers: ScriptedTurnScript gains `reasoning`; ScriptedToolCallingModel emits a `.reasoning` entry before the answer; ScriptedMarkerTools gains StructuredMarkerTool (@Generable output -> `.structure` tool-output segment); StubSessionBackend gains an optional StubBackendRegistry that records every backend and clone (the hook that reaches the live post-fold backend a fold's replacingTranscript swap installs); RouterTestFixtures.makeRouter gains `id`/`recordingsDir` parameters with defaults.

    Verification: `swift build --build-tests` clean. `swift test` (ungated): 891 + 27 + 24 = 942 tests, 0 failures; the 1 known issue is the pre-existing deliberate withKnownIssue in BoundedWait. Note: the verification run executed twice with identical green results — the first invocation piped through `tail` and lost its stored output, so one clean re-run captured the counts. Not a soak; both runs green.
  timestamp: 2026-08-12T17:59:51.588353+00:00
- actor: claude-code
  id: 01kzvj353eskwwd252tsykzcj4
  text: |-
    ### implement — changed
    - evidence: 7 files — Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift (new), Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedTurnScript.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift, Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift, Tests/FoundationModelsRouterTests/Helpers/StubSessionBackend.swift, Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift. One ungated `swift test`: 942 tests (891 + 27 + 24), 0 failures. Follow-up product task ^ja94kb6 filed for the two fixable mapper fidelity degradations.
    - next: review the task (/review), then implement ^ja94kb6 to tighten group 1's canonical-form comparison.
  timestamp: 2026-08-12T18:00:00.878198+00:00
depends_on:
- 01KZR9YPHRGDCZ26R5BH1008KB
- 01KZR9Z6QH9WVXVSX9T6Z1MSG1
- 01KZRAH9TQCGSJYTENYXSGJNEY
position_column: doing
position_ordinal: '8180'
title: 'Restore fidelity tests: rich content, multi-fold, driven forks'
---
## Problem

The always-run test suite proves restorability only for stub text turns and only structurally:

1. **Rich content never traverses the full disk path.** Only text `.prompt`/`.response` entries go recorder -> JSONL -> `effectiveTranscript` (TranscriptReconstructionTests' backend appends text only, Tests/FoundationModelsRouterTests/TranscriptReconstructionTests.swift:106-165). No tool turn, `.reasoning` entry, `.structure` segment, attachment, or `.custom` segment ever makes the round trip through disk.
2. **Mapper equality gaps.** `.structure`, `.attachment` (URL-backed), and `.custom` segments have no equality-level round trip — tests cherry-pick fields (TranscriptEntryMapperTests.swift:184-205, :457-488, :227-247). No entry with multiple or mixed segments goes through the mapper. No multi-call `.toolCalls` round trip.
3. **Multi-fold restore** is tested only with hand-fabricated checkpoint events (TranscriptReconstructionTests.swift:915-974). No test folds a live session twice and restores it.
4. **Driving a restored fork** is proven semantically in exactly one gated integration assertion (`reply.contains("42")`, Tests/FoundationModelsRouterIntegrationTests/SessionTreeRestorationIntegrationTests.swift:355), skipped by default.

## Proposed solution

Add always-run tests (stub/scripted backends, no GPU):

1. Drive a scripted tool turn (multi-call, with a `.structure` output segment and a `.reasoning` entry) through a real session, restore from disk, and assert entry-array equality against the live backend transcript — the same `Array(reconstructed) == backend.transcriptEntries()` check the text tests already use.
2. Add mapper round-trips with full `Transcript.Entry` equality for: an entry with mixed segments, a multi-call `.toolCalls`, a URL-backed attachment, and a registered `.custom` segment.
3. Fold a live session twice (scripted summarizer), restore, and assert the restored transcript equals the live post-second-fold transcript. This test runs against the fixed checkpoint semantics (tasks ^h1008kb and ^6z1msg1).
4. Drive a restored fork with a scripted model whose script proves continuity (the reply depends on an entry inherited from the parent), so the semantic continuation claim no longer lives only behind the integration gate.

## Acceptance

- All four test groups run in the default (ungated) suite and pass.
- At least one test asserts full entry-array equality for a transcript containing all six entry kinds. #transcript