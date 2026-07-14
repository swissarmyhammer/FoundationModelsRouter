---
comments:
- actor: claude-code
  id: 01kxh93apy07krr9zzk0t6nb4s
  text: |-
    Implemented via TDD.

    Research: confirmed SessionIndexRecord/SessionIndexWriter (Recording/SessionIndex.swift) already carry parentId/forkedAtEntryCount lineage, used today only by RoutedSessionActor.fork(workingDirectory:) (Session/RoutedSession.swift) and RoutedModel.restoreSessionTree(root:registry:) (Recording/SessionTreeRestoration.swift, which is the actual "resume from disk" path today but is stuck going through LoadedLLMContainer.makeSession(transcript:) — hardcoded tools: [] in LiveModelLoader.swift). TranscriptTree.effectiveTranscript(forSession:registry:) (TranscriptReconstruction.swift) reconstructs an SDK-native Transcript from a session's effective entry-kind events, and is exactly what a RecordingLanguageModel handle needs to prime its last-seen diff baseline.

    Implementation:
    - RecordingLanguageModelState (Recording/RecordingLanguageModel.swift) gained three new fields: `parentId: ULID?`, `forkedAtEntryCount: Int`, and `lastSeen` is now primed from an `initialTranscript` init parameter (previously hardcoded `Transcript(entries: [])`). All three default to the prior fresh-handle behavior (nil/0/empty) so the existing zero-arg `makeLanguageModel()` factory and all its tests are unaffected. Three previously-hardcoded `parentId: nil`/`forkedAtEntryCount: 0` sites (recordSessionMetaIfNeeded, diffAndRecord's TranscriptDiffer.diff call, registerSessionIndexRecordIfNeeded's SessionIndexRecord) now read the stored properties.
    - New factory `RoutedLLM.makeLanguageModel(resuming sessionId:registry:) throws -> (handle: RecordingLanguageModel, transcript: Transcript)` in RoutedLLM.swift: loads the TranscriptTree under the router's recordingsRoot, reconstructs `sessionId`'s effective transcript, mints a fresh child handle primed with that transcript (parentId: sessionId, forkedAtEntryCount: restoredTranscript.count, initialTranscript: restoredTranscript), and hands the transcript back so the caller builds `LanguageModelSession(model: handle, tools: realTools, transcript: restored)` themselves — bypassing the container factory entirely, which is how a resumed session finally gets real tools. Reused `SessionTreeRestorationError.noDurableRecordingsRoot` rather than inventing a new error type. The child's directory is nested flatly (same helper as a fresh root handle/session), not physically under the parent's directory — SessionIndexRecord.path is an independent lookup, so lineage is carried entirely by parentId/forkedAtEntryCount, not directory nesting.

    Tests: Tests/FoundationModelsRouterTests/RecordingHandleResumeTests.swift (3 tests) — child transcript.jsonl holds only post-resume events with correct parentId/forkedAtEntryCount lineage; resuming with a different (non-empty) tool set drives a real tool-using turn; TranscriptTree reconstruction over parent+child yields the full conversation. Watched all three fail to compile first (missing API), then implemented to green.

    Adversarial double-check (via really-done) found one real gap: none of the three tests could detect an *overcount* of forkedAtEntryCount, since Array.prefix(_:) silently clamps and every test scenario had the resume-to-full-parent-state shape. Fixed by extending the reconstruction test to drive the PARENT handle for one more turn AFTER the resume point, then asserting the child's reconstructed conversation does not include that later parent turn. Verified via mutation testing: temporarily inflated forkedAtEntryCount by +100 in production code — the strengthened test failed exactly as predicted ("parent continues after resume" leaked into the child's reconstruction); reverted and confirmed green again.

    Full suite: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 326 tests / 39 suites green, gated integration suite (14 tests / 4 suites) correctly skipped without FM_ROUTER_INTEGRATION_TESTS=1. Zero warnings, zero failures.
  timestamp: 2026-07-14T21:39:01.470820+00:00
depends_on:
- 01KXGGZ3ETZEH6PMG3VEM16AZ8
position_column: doing
position_ordinal: '80'
title: Resume and fork lineage for recording handles
---
## What
Add resume support to the recording handle: makeLanguageModel(resuming: sessionId) (exact spelling per taste — a parameter on the factory). Semantics:

- primes the handle last-seen Transcript with the restored session transcript so the FIRST generate call records only NEW entries — never re-records the whole history into a fresh directory
- writes a SessionIndexRecord carrying parentId and forkedAtEntryCount, reusing the existing lineage semantics from Recording/SessionIndex.swift
- pairs with LanguageModelSession(model: handle, tools: realTools, transcript: restored) — note this is how restored sessions finally get real tools, which the current fork/restore path (tools hardwired empty in LiveModelLoader) cannot do

## Acceptance Criteria
- [x] Recording a session, resuming it, and continuing yields a child session whose transcript.jsonl contains only post-resume events
- [x] The child SessionIndexRecord references the parent id and fork entry count; TranscriptTree / MergedTranscript reconstruction over parent plus child yields the full conversation
- [x] Resuming with a different tool set works

## Tests
- [x] Tests/FoundationModelsRouterTests/RecordingHandleResumeTests.swift — record N entries via a stub, resume, continue one turn, assert child directory has only the new events and the lineage fields are correct; reconstruction test asserts the merged transcript equals the full conversation
- [x] swift test green (DEVELOPER_DIR set)

## Workflow
- Use /tdd.

#coding-harness

## Implementation notes

`RoutedLLM.makeLanguageModel(resuming sessionId: ULID, registry: CustomSegmentRegistry = CustomSegmentRegistry()) throws -> (handle: RecordingLanguageModel, transcript: Transcript)` — added in Sources/FoundationModelsRouter/RoutedLLM.swift. Loads the TranscriptTree under the router's recordingsRoot, reconstructs the resumed session's effective transcript via `TranscriptTree.effectiveTranscript(forSession:registry:)`, and mints a fresh child `RecordingLanguageModel` handle whose `RecordingLanguageModelState` is primed with `parentId: sessionId`, `forkedAtEntryCount: restoredTranscript.count`, and `initialTranscript: restoredTranscript` (so `lastSeen` starts at the resumed transcript instead of empty). Returns the transcript alongside the handle so the caller builds `LanguageModelSession(model: handle, tools: realTools, transcript: restored)` directly, bypassing the container's `makeSession(transcript:)` (which hardcodes `tools: []`).

`RecordingLanguageModelState` gained `parentId: ULID?` and `forkedAtEntryCount: Int` (both default to the prior fresh-handle values so `makeLanguageModel()` is unaffected), and `lastSeen` is now seeded from an `initialTranscript` init parameter instead of a hardcoded empty transcript. Three previously-hardcoded `parentId: nil` / `forkedAtEntryCount: 0` sites now read these stored properties.

Adversarial review (via really-done) found the initial test suite could not detect an overcounted `forkedAtEntryCount` (Array.prefix silently clamps). Strengthened the reconstruction test to drive the parent handle one more turn after resume and assert it does not leak into the child's reconstruction; verified via mutation testing (temporarily inflating the count) that this catches the regression.

Full `swift test` run: 326 tests / 39 suites green, gated integration suite correctly skipped, zero warnings.