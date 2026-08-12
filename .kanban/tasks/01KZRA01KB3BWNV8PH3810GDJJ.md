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
- actor: claude-code
  id: 01kzvjmjwh4kd6hx909v2ctfx4
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 4b8e883); engine gave 6 findings; 2 dropped by the written waiver for tests that existed before this commit (RouterTestFixtures.swift:28, ScriptedToolCallingModel.swift:43); 4 findings stay — ScriptedMarkerTools.swift:204, RestoreFidelityTests.swift:71, RestoreFidelityTests.swift:104, RestoreFidelityTests.swift:255
    - next: obey the 4 findings in the new "## Review Findings (2026-08-12 13:01)" section, then request a new review pass
  timestamp: 2026-08-12T18:09:32.049511+00:00
- actor: claude-code
  id: 01kzvjnmm26sec9er5g8cnsdk8
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 7 files; four ungated test groups (rich tool turn via full disk path, mapper full-entry round trips, two live folds then restore, driven restored fork); follow-up ^ja94kb6 filed for two fixable mapper losses
    - test: green — swift test, 942 tests (891 + 27 + 24), 0 failures (the one implement run is the test evidence)
    - commit: 4b8e883
    - review: findings — 4 open: ScriptedMarkerTools.swift:204, RestoreFidelityTests.swift:71, :104, :255 (2 waived, pre-existing tests)
  timestamp: 2026-08-12T18:10:06.594173+00:00
- actor: claude-code
  id: 01kzvk35srexq6tfkseb1v27cz
  text: |-
    Research for the four open findings:
    - ScriptedMarkerTools.swift:204 — `NonStringMarkerTool` and the new `StructuredMarkerTool` build outputs of different types with different field lists (`NonStringToolOutput(text:)` is `PromptRepresentable`; `StructuredMarkerOutput(marker:)` is `@Generable`). The two tools also test different mounting routes. No shared function can hold the two bodies. The repo precedent for this case is the `// sah:allow duplication <reason>` marker (see Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift and RoutedLLM.swift). The duplication rule text says: put the marker on the line above the flagged definition and write the reason.
    - RestoreFidelityTests.swift:71 and :255 — `recencyWindowOnlyEstimate` and `driveTurns` ARE defined: they are the shared free functions in Tests/FoundationModelsRouterTests/Helpers/CompactionFoldFixtures.swift (lines 46 and 27). The suite compiles and all tests pass, so the "not defined / uncompilable" premise is not correct. The finding's requirement sentence is: "The pattern ... should be consistent: either imported as a shared helper or defined locally like peer test files do." A local copy would break the reuse rule ("call the existing one") and the duplication rule. The correct fix is the first branch: make the shared-helper pattern consistent. Two private clones of `recencyWindowOnlyEstimate` exist: AutoCompactionTests.swift:169 (literal 4 == defaultKeepRecentTurns) and GuidedGenerationTests.swift `autoCompactionRecencyWindowOnlyEstimate`. Remove them and call the shared helper. `driveTurns` has exactly one definition already. Add a pointer to the shared fixtures in the RestoreFidelityTests suite doc so a reader finds the definitions.
    - RestoreFidelityTests.swift:104 — six private copies of `routerDirectory` exist (RestoreFidelityTests, SessionTreeRestorationTests, TranscriptReconstructionTests, CompactionSegmentTests, TranscriptTreeTests, ForkAfterCompactionRestorationTests). Extract one shared `RouterTestFixtures.routerDirectory(routerId:recordingsDir:)` and make all six files call it, as the finding asks.
  timestamp: 2026-08-12T18:17:30.168269+00:00
- actor: claude-code
  id: 01kzvm38xtq6j5ksestzy0xtyj
  text: |-
    All four findings are fixed. What changed, and why:

    1. ScriptedMarkerTools.swift:204 — added `// sah:allow duplication <reason>` on the line above `NonStringMarkerTool`. The two tools build outputs of different types with different field lists (`NonStringToolOutput(text:)` vs `@Generable StructuredMarkerOutput(marker:)`) and each exercises a different mounting route, so no shared function can hold the two bodies. This is the repo's written pattern for that case (TranscriptEvent.swift, RoutedLLM.swift).
    2. RestoreFidelityTests.swift:104 — extracted the shared `RouterTestFixtures.routerDirectory(routerId:recordingsDir:)` and made ALL six files that had a private copy call it: RestoreFidelityTests, SessionTreeRestorationTests (also one inline `appendingPathComponent` construction), TranscriptReconstructionTests, CompactionSegmentTests, TranscriptTreeTests, ForkAfterCompactionRestorationTests. The six private definitions are gone.
    3. RestoreFidelityTests.swift:71 and :255 — the two helpers ARE defined: they are the shared free functions in Helpers/CompactionFoldFixtures.swift (`recencyWindowOnlyEstimate` line 46, `driveTurns` line 27), so the suite compiled and passed before this fix. The finding's requirement sentence gives two consistent patterns; a local copy would break the reuse rule ("call the existing one, not duplicate the capability") and the duplication rule, so the shared-helper branch is the correct one. To make that pattern consistent, the two private clones of `recencyWindowOnlyEstimate` are removed (AutoCompactionTests.swift:169 and GuidedGenerationTests' `autoCompactionRecencyWindowOnlyEstimate`; both used the literal 4, equal to `defaultKeepRecentTurns`, so behavior is identical) and their call sites now use the shared helper. The RestoreFidelityTests suite doc now names the shared fixtures so a reader finds the definitions.

    Sweep of the task's other files (ScriptedTurnScript, ScriptedToolCallingModel, StubSessionBackend, TranscriptEntryMapperTests): `driveTurns` has exactly one definition, no other `routerDirectory` or estimate clones exist, and no new near-duplicate pairs were added.

    Verification: `swift build --build-tests` clean; ONE ungated `swift test`: 942 tests (891 + 27 + 24), 0 failures; the 1 known issue is the pre-existing deliberate withKnownIssue in BoundedWait. Behavior unchanged — no test body changed, only helper consolidation.
  timestamp: 2026-08-12T18:35:01.946209+00:00
- actor: claude-code
  id: 01kzvm3nyf3ty84b2a8svwtcfj
  text: |-
    ### implement — changed
    - evidence: 10 files — Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift (sah:allow duplication marker on NonStringMarkerTool), Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift (new shared routerDirectory(routerId:recordingsDir:)), Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift, SessionTreeRestorationTests.swift, TranscriptReconstructionTests.swift, CompactionSegmentTests.swift, TranscriptTreeTests.swift, ForkAfterCompactionRestorationTests.swift (private routerDirectory copies removed, call sites moved to the shared helper), AutoCompactionTests.swift, GuidedGenerationTests.swift (private recencyWindowOnlyEstimate clones removed, call sites moved to the shared CompactionFoldFixtures helper). One ungated `swift test`: 942 tests (891 + 27 + 24), 0 failures.
    - next: run /review for a fresh pass over the fixes; the task stays in doing.
  timestamp: 2026-08-12T18:35:15.279213+00:00
- actor: claude-code
  id: 01kzvn7yxn8dxa7ryc0nw5p4ne
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit 3ec2566); engine counts 15 confirmed; 12 dropped by the written waiver for tests that existed before this commit; 3 open — Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:186, Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift:509, Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift:251
    - next: resolve the 3 open findings in the section "Review Findings (2026-08-12 13:36)", then run the review again
  timestamp: 2026-08-12T18:55:04.117477+00:00
- actor: claude-code
  id: 01kzvn91d9n7d54pbmm2n7d7v1
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 10 files; sah:allow duplication marker on NonStringMarkerTool, shared routerDirectory helper replaces six private copies, two recencyWindowOnlyEstimate clones removed
    - test: green — swift test, 942 tests (891 + 27 + 24), 0 failures (the one implement run is the test evidence)
    - commit: 3ec2566
    - review: findings — 3 open, all NEW (different from iteration 1): AutoCompactionTests.swift:186, GuidedGenerationTests.swift:509, RestoreFidelityTests.swift:251 (12 waived, pre-existing tests). Guardrail not armed: each round gives different findings.
  timestamp: 2026-08-12T18:55:39.433067+00:00
- actor: claude-code
  id: 01kzvnhg9rjq0tj8jrv5v4s0kb
  text: |-
    Resolution of the three findings of 2026-08-12 13:36. All three make the same claim: a call to a helper in Helpers/CompactionFoldFixtures.swift is not accessible because the file is not imported. The claim conflicts with observable reality, and no code change is necessary:

    1. Package.swift declares the test target with path Tests/FoundationModelsRouterTests and no exclude, so Helpers/CompactionFoldFixtures.swift compiles into the same module as the three call sites. `recencyWindowOnlyEstimate` and `driveTurns` are internal free functions, and each file of a target sees the internal declarations of the other files. Swift does not have a file-level import inside one module.
    2. The two proposed fixes cannot compile: `import CompactionFoldFixtures` names no module, and `CompactionFoldFixtures.recencyWindowOnlyEstimate(...)` names no type (CompactionFoldFixtures is only a file name). The `RouterTestFixtures.routerDirectory()` pattern the first finding cites is different: `RouterTestFixtures` is an enum type, so its calls show a type qualifier.
    3. Semantics check: the deleted local copies in AutoCompactionTests and GuidedGenerationTests had the same body as the shared helper (`keepRecentTurns: 4`, equal to `defaultKeepRecentTurns = 4`; verified against the diff of commit 3ec2566). `driveTurns` has exactly one definition in the repository.
    4. Evidence: the working tree is clean at commit 3ec2566; `swift build --build-tests` is clean; ONE ungated `swift test` run gives 942 tests (891 + 27 + 24) in 100 suites, 0 failures, exit code 0. The one known issue is the pre-existing deliberate withKnownIssue in BoundedWait.

    Each of the three items is checked off on the card with this evidence. The card tags were re-supplied as ["transcript"] and the description was re-verified after the update.
  timestamp: 2026-08-12T19:00:16.824985+00:00
- actor: claude-code
  id: 01kzvnhr6ha6552gmxn3bt5ma1
  text: |-
    ### implement — no-change
    - evidence: 0 source files changed; card description updated only (three findings checked off with evidence). The three claims are not correct: the helpers are internal free functions in the same test target (Package.swift, path Tests/FoundationModelsRouterTests, no exclude), so no import exists or is necessary. `swift build --build-tests` clean; ONE ungated `swift test`: 942 tests (891 + 27 + 24), 0 failures, exit code 0.
    - next: run /review for a fresh pass; the task stays in doing.
  timestamp: 2026-08-12T19:00:24.913913+00:00
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
- At least one test asserts full entry-array equality for a transcript containing all six entry kinds.

## Review Findings (2026-08-12 13:01)

- [x] `Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift:204` — type `NonStringMarkerTool` is a near-duplicate of `StructuredMarkerTool` at Tests/FoundationModelsRouterTests/Helpers/ScriptedMarkerTools.swift:165 (63 tokens, 95% alike).
- [x] `Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift:71` — Function `recencyWindowOnlyEstimate` is called but not defined in RestoreFidelityTests, while clone-siblings evidence shows this helper is defined locally in other test suites (e.g., AutoCompactionTests.swift:168). The pattern of computing transcript size estimates should be consistent: either imported as a shared helper or defined locally like peer test files do. Define `recencyWindowOnlyEstimate` as a static method in RestoreFidelityTests, mirroring the implementation in AutoCompactionTests and other similar test suites.
- [x] `Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift:104` — The `routerDirectory` function reimplements directory path construction that already exists in multiple other test files (0.97–0.98 similarity), instead of calling or extending a shared utility. Extract `routerDirectory` to a shared test utility location (e.g., RouterTestFixtures.swift or CompactionFoldFixtures.swift) so all test files that need to construct router recording directories call the same shared implementation rather than duplicating it.
- [x] `Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift:255` — Function `driveTurns` is called but not defined anywhere in RestoreFidelityTests. This test helper is needed to execute warm-up turns before fold operations, but the implementation is missing, making the test uncompilable. Define `driveTurns` as a static helper method in RestoreFidelityTests that drives N turns on a session (similar to patterns in other fold-testing suites).

### Waived findings (2026-08-12 13:01)

- Dropped: `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:28` (magic numbers). The line is from commit 3b0f756 (2026-08-04). This commit did not change the line. The written waiver for tests that existed before this commit applies.
- Dropped: `Tests/FoundationModelsRouterTests/Helpers/ScriptedToolCallingModel.swift:43` (`Executor` near-duplicate of `ScriptedToolCallingModel`). The two types are from commit fe0a645 (2026-08-10). This commit did not change the anchor lines, and the duplication existed before this commit. The written waiver for tests that existed before this commit applies.

## Review Findings (2026-08-12 13:36)

- [x] `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:186` — The change deleted the private static function `recencyWindowOnlyEstimate` from this file, but line 186 still calls it directly without qualification or import. This breaks the call site because the function no longer exists in this file and is not imported from its new home in the shared fixtures. Qualify the call to use the shared version: either add `import CompactionFoldFixtures` at the top and call it directly, or call it as `CompactionFoldFixtures.recencyWindowOnlyEstimate(expectedWarmUpEntries())`. This mirrors the pattern correctly used in CompactionSegmentTests.swift and ForkAfterCompactionRestorationTests.swift where `RouterTestFixtures.routerDirectory()` is properly qualified after deletion of local copies. — **Resolved 2026-08-12, not a defect.** The claim is not correct: the call compiles and the tests pass. Package.swift puts all of Tests/FoundationModelsRouterTests, with the Helpers directory, in one test target with no exclude, so `recencyWindowOnlyEstimate` is an internal free function in the same module as this call site. Swift does not have a file-level import inside one module. `import CompactionFoldFixtures` names no module and `CompactionFoldFixtures.` names no type, so the two proposed fixes cannot compile. `RouterTestFixtures.routerDirectory()` shows a qualifier because `RouterTestFixtures` is an enum type, not an import. The deleted local copy had the same body (`keepRecentTurns: 4`, equal to `defaultKeepRecentTurns`), so the semantics did not change. Evidence: `swift build --build-tests` is clean; one ungated `swift test` run gives 942 tests (891 + 27 + 24), 0 failures, exit code 0.
- [x] `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift:509` — The change removed the local `autoCompactionRecencyWindowOnlyEstimate` function but replaced it with a call to `recencyWindowOnlyEstimate`. This replacement function is defined in Helpers/CompactionFoldFixtures.swift, which is not imported at the top of the file, making the call inaccessible and breaking the code. Add an import for CompactionFoldFixtures at the top of the file, or verify that recencyWindowOnlyEstimate is exported from FoundationModelsRouter and accessible through the @testable import. — **Resolved 2026-08-12, not a defect.** `recencyWindowOnlyEstimate` is an internal free function in the same test target as this file, so the call needs no import and no export from FoundationModelsRouter. The removed local copy had the same body (`keepRecentTurns: 4`, equal to `defaultKeepRecentTurns`), so the semantics did not change. Evidence: `swift build --build-tests` is clean; one ungated `swift test` run gives 942 tests, 0 failures.
- [x] `Tests/FoundationModelsRouterTests/RestoreFidelityTests.swift:251` — Line 251 calls `driveTurns`, which is defined in Helpers/CompactionFoldFixtures.swift and is not imported by this file. The call is inaccessible. Add an import for CompactionFoldFixtures to make `driveTurns` accessible. — **Resolved 2026-08-12, not a defect.** `driveTurns` is an internal free function in the same test target as this file, so the call needs no import. It has exactly one definition in the repository (Helpers/CompactionFoldFixtures.swift). Evidence: `swift build --build-tests` is clean; one ungated `swift test` run gives 942 tests, 0 failures.

### Waived findings (2026-08-12 13:36)

- Dropped: `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:57` (add a Sendable invariant doc comment to `ConfiguredLLMContainer`). The line is from commit c5a6223 (2026-07-24). This commit did not change the line. The written waiver for tests that existed before this commit applies.
- Dropped: `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:464` (add a Sendable invariant doc comment to `ReplaceSpy`). The line is from commit c5a6223 (2026-07-24). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/AutoCompactionTests.swift:487` (`lastBackend` is assignOnlyProperty). The line is from commit c5a6223 (2026-07-24). This commit did not change the line or the reads of the property. The written waiver for tests that existed before this commit applies. The synthesized ==/hash waiver does not apply here, because `ReplaceSpy` is a class.
- Dropped: `Tests/FoundationModelsRouterTests/ForkAfterCompactionRestorationTests.swift:33` (add a Sendable invariant doc comment to `RetainingLLMContainer`). The line is from commit 282a598, which came before this commit. This commit did not change the line. The written waiver for tests that existed before this commit applies.
- Dropped: `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift:147` (remove the private `StubMetadataSource` duplicate). The line is from commit e0d1002 (2026-06-30). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/GuidedGenerationTests.swift:188` (remove the private `makeTempDir()` duplicate). The line is from commit e0d1002 (2026-06-30). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift:28` (magic numbers). The line is from commit 3b0f756 (2026-08-04). This commit did not change the line. The same written waiver applies. The pass of 2026-08-12 13:01 also dropped this finding.
- Dropped: `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:34` (remove the private `StubEmbeddingContainer` duplicate). The line is from commit ef4985f (2026-07-10). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:43` (remove the private `StubProbe` duplicate). The line is from commit ef4985f (2026-07-10). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift:49` (remove the private `StubMetadataSource` duplicate). The line is from commit ef4985f (2026-07-10). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift:21` (move the duplicated `CannedLLMContainer` to the shared fixtures). The line is from commit ad1cb12 (2026-07-10). This commit did not change the line. The same written waiver applies.
- Dropped: `Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift:178` (reduce the complexity of `buildBranchingTree`). The line is from commit ad1cb12 (2026-07-10). This commit did not change the line. The same written waiver applies. #transcript