---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6htwbm60n7b2xm4jay87a2w
  text: |-
    ### implement — changed
    - evidence: Extras updated to d692c69 (Package.resolved is gitignored, so the pin is local; no other breaking change). SessionConfiguration.transcriptReader added. The reader goes to the root site, the recorded-spawn site (RoutedModel.makeSessionToolWiring), the restore path (new transcriptReader argument on restoreSession and restoreSessionTree, because the recording cannot hold a live reader), and the ToolMounting.makeSessionMounted helper. The child site of a live parentCall keeps the parent reader in Extras (MountSite.childSite); a test proves it. TranscriptEvent.read(sessionDirectory:) added in Recording/MergedTranscript.swift (one folder, same schema check and torn-line rule, sorted by (ts, seq), no child folders; a missing transcript file gives no events). Tests: SessionTranscriptReaderTests (root, recorded spawn, restored, parent-call child, helper, no reader gives noSource, unknown id gives notFound), MergedTranscriptPublicSurfaceTests (skips child folders, sorts), MergedAndRedactionTests (newer schema throws the typed error). Test helpers ContextStore, ContextRecordingTool and ToolDrivingLLMContainer moved from RestoredSessionIdentityTests to Helpers/ToolContextRecording.swift for reuse. Full suite: 2424 tests in 286 suites passed, zero warnings. No format run, no commit, no push.
    - next: review
  timestamp: 2026-11-03T23:11:03.814220+00:00
- actor: claude-code
  id: 01m6hv3xvv98s0nnyjj1s8s2hb
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (90d5a635): 1 finding (1 confirmed, 3 refuted)

    ## Review Findings (2026-11-03 17:11)

    - [ ] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift:171` `reuse/reuse` — The new one-folder future-version test copies the setup of the existing merge future-version test: the temp directory, the canonical path, the recorder, the session folder, and the future-version record. The copy is nearly line for line, so a change to either test's setup must be made in both. Move the shared setup (canonical temp directory, one session folder with a future-version index) into a helper in this suite. Have both tests call it and pass in the read under test.

    - next: implementer fixes the finding, then review again
  timestamp: 2026-11-03T23:15:11.867860+00:00
- actor: claude-code
  id: 01m6hv706942zszq2m7erej41g
  text: |-
    ### implement — changed
    - evidence: 1 file, Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift. Full suite: 2424 tests in 286 suites passed, zero warnings.
    - [x] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift:171` `reuse/reuse` — fixed. New helper `expectFutureVersionRefusal(_:)` holds the shared setup (canonical temp directory, one session folder with a future-version index, the expected typed error). The merge test and the one-folder read test each call it and pass in the read under test. Same cause removed from the whole file: new `makeCanonicalTempDir()` reuses `makeTempDir()`; the two tests that built a temp directory by hand (merged order test, level off creates no file test) now call `makeTempDir()`.
    - next: review
  timestamp: 2026-11-03T23:16:52.553303+00:00
- actor: claude-code
  id: 01m6hv92zd01n8qeygq7hd2a2g
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (627e0cc0): 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 1 file reviewed; 2 .kanban files skipped by .reviewignore.
    - next: none. Card moved to done. Not pushed.
  timestamp: 2026-11-03T23:18:00.941259+00:00
position_column: done
position_ordinal: ffffffffeb80
title: Pass a host transcript reader to every MountSite; add a one-folder TranscriptEvent read
---
The ACP agent host asks for two changes. The user said yes ("Yes, tell the Router session"). Plan first, no code until the coordinator agrees. No push until the user types "commit and push" in this session.

## Plan
1. Update the Extras dependency to d692c69 or newer (it has SessionTranscriptReader and the optional transcriptReader on MountSite and ToolContext). Stop sourcekit-lsp first and use --manifest-cache local (see memory).
2. Add an optional `transcriptReader: (any SessionTranscriptReader)?` to SessionConfiguration (default nil). Keep the name that the Extras protocol uses.
3. Pass it to every MountSite that Router makes: the root site and the recordedSpawn site in RoutedModel.makeSessionToolWiring (RoutedLLM.swift), the restore path, and the helper in ToolOutputCapping.swift. The childSite of a live parent call keeps the parent reader already (Extras).
4. Add a public one-folder read in TranscriptEvent: `TranscriptEvent.read(sessionDirectory:)`. It reads the one transcript.jsonl in that folder, with the same schema check and the same torn-line rule as `merged(under:)`. It sorts by (ts, seq). It does not walk child folders.
5. Tests (TDD): a reader given in the configuration is visible through ToolContext.transcript(of:) in a root session, a recorded spawn and a restored session; a session with no reader gives nil; the one-folder read returns only that folder and skips child folders; a newer schema version throws.

## User decisions for the reader
Any session Router can reach; disk only (no flush); an unknown id throws SessionTranscriptError.notFound.

## Open point
Router does not build the reader. The host builds it (ACP card 01M6HAKCESA2PE427MQZGQXJ7Z) using the one-folder read. #subagents