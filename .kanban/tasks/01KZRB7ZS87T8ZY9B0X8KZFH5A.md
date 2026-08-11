---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzs793vk2zgt2tjwqexbwjaj
  text: |-
    Research findings:

    - JSONLRecorder (Sources/FoundationModelsRouter/Recording/Sinks.swift) appends through cached FileHandles keyed by directory path. Each event becomes one write call in appendJSONLine (Sources/FoundationModelsRouter/Recording/JSONLAppend.swift). No sync call exists.
    - The codebase already has a "turn close" vocabulary: both diff paths (RecordingLanguageModel.diffAndRecord and RoutedSessionActor.recordTranscriptDelta) stamp the turn's token usage onto the LAST `.response`-kind event of a diff — the docs call it "the turn-final `.response`-kind event". The sync point will be: synchronize (fsync) the target directory's handle after each append whose kind is `.response`.
    - Test seam for the sync assertion: JSONLRecorder gets an internal init that injects the handle opener. A small internal protocol with `write(contentsOf:)` and `synchronize()` lets FileHandle conform unchanged and lets a test spy record the call order. The public init keeps its exact signature and delegates.
    - TranscriptTree.decodeEvents (TranscriptTree.swift) decodes each line with a raw `try decoder.decode` — one bad byte fails the whole load with an error that names no file. It is called from three places, all with the session ULID in scope: rawNode (load path, for compactionCount), events(forSession:), and entryKindEvents. Plan: decode from Data with byte-offset tracking; a decode failure on the LAST non-empty line logs a warning (file path + byte offset) and drops the line; a failure on any earlier line throws a new `TranscriptTreeError.transcriptLineCorrupt(session:file:)`.
    - MergedTranscript.swift has its own decode loop; the card names TranscriptTree only, so that loop stays as is.
    - Fixtures: SessionSidecar.write + JSONLRecorder produce a valid on-disk session; ModelRef is ExpressibleByStringLiteral; ULID() for ids (board rule: ULID over UUID for generated ids — the directory-name id IS a ULID here).

    Plan (test-first): torn-tail tests parameterized over several truncation byte offsets; a mid-file corruption test expecting the typed error (TranscriptTreeError is Equatable, so #expect(throws:) works); a sync-order test with a spy handle asserting synchronize fires exactly after the `.response` append and never after the others.
  timestamp: 2026-08-11T20:12:33.011175+00:00
- actor: claude-code
  id: 01kzsbhkna33qsy2dx6kfsd1cg
  text: |-
    Implementation is complete. All work was test-first (RED, then GREEN).

    What changed:
    1. Sync policy, defined and applied on JSONLRecorder (Sources/FoundationModelsRouter/Recording/Sinks.swift). The doc comment has a new "Durability" section. Each event is one write call. After each `.response`-kind append (the turn-close event), the recorder synchronizes (fsync) the target directory's handle. A sync failure is logged, not thrown — the same best-effort policy as the writes.
    2. Test seam: a new internal protocol `TranscriptAppendHandle` (write + synchronize) in Sources/FoundationModelsRouter/Recording/JSONLAppend.swift. FileHandle conforms with no change. JSONLRecorder has a new internal init that injects the handle opener; the public init is unchanged and delegates to it.
    3. Torn-tail tolerance in Sources/FoundationModelsRouter/Recording/TranscriptTree.swift: `decodeEvents(in:forSession:)` now reads the file as bytes, tracks each line's byte offset, drops a final line that does not decode, and writes a warning that names the file path and the byte offset. A corrupt line that is NOT the last one throws the new `TranscriptTreeError.transcriptLineCorrupt(session:file:)`, which names the session and the file. All three call sites (load path, events(forSession:), entryKindEvents) pass the session id. Doc comments on load, rawNode, and events(forSession:) state the new contract.
    4. Tests in Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift: (a) torn final line, parameterized over three kept-byte counts (1, 24, 60) — the tree loads and events(forSession:) returns the turn-before state; (b) mid-file corruption — load throws the typed error with the correct session id and file; (c) a spy handle asserts the exact call order [write, write, write, sync, write, write, sync] for the kinds [session, prompt, response, prompt, response] — no kill needed.

    Verification: `swift build` clean (only the accepted vendored mlx-swift "missing creator" warning). One full ungated `swift test` run: 830 tests in 79 suites passed with the one accepted BoundedWait known issue; the two hermetic gated-target wiring runs (27 and 24 tests) also passed.

    Out of scope, noted for a possible follow-up: MergedTranscript.swift keeps its own raw decode loop; the card names TranscriptTree only.
  timestamp: 2026-08-11T21:27:05.642651+00:00
- actor: claude-code
  id: 01kzsbhsm9j027heek067m0s8c
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Recording/Sinks.swift, Sources/FoundationModelsRouter/Recording/JSONLAppend.swift, Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift; swift build clean; one full swift test run: 830 tests in 79 suites passed (1 accepted BoundedWait known issue)
    - next: /review
  timestamp: 2026-08-11T21:27:11.753961+00:00
- actor: claude-code
  id: 01kzsc1m6w7487n9e3td8ykynj
  text: |-
    ### review — findings
    - evidence: 3 findings — Sources/FoundationModelsRouter/Recording/JSONLAppend.swift:102, Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:480, Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift:34 (scope: review sha HEAD~1..HEAD, commit ebfcd18)
    - next: /implement the checklist in the "Review Findings (2026-08-11 16:28)" section, then /review again
  timestamp: 2026-08-11T21:35:50.492996+00:00
- actor: claude-code
  id: 01kzsc2aks5bcs64z4hg51c91b
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 4 files, turn-close fsync policy + torn-tail tolerance + typed mid-file error, test-first (red then green)
    - test: green — one full swift test run, 881 tests (830+27+24), 0 failures
    - commit: changed — ebfcd18
    - review: findings — Sources/FoundationModelsRouter/Recording/JSONLAppend.swift:102 (magic number), Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:480 (MergedTranscript clone-sibling must get the same torn-tail tolerance), Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift:34 (assignOnly directory property)
  timestamp: 2026-08-11T21:36:13.433820+00:00
- actor: claude-code
  id: 01kzscbmmy7mnffrzbkwprb8ga
  text: |-
    Research for the three review findings:

    1. JSONLAppend.swift has one unnamed numeric literal: the newline byte 0x0A in appendJSONLine. This is the only unnamed literal in the file. Fix: declare one internal named constant jsonlNewlineByte in JSONLAppend.swift. The writer and the shared reader will use it. The private newlineByte in TranscriptTree.swift moves out with the extraction (item 2), so the module keeps one definition.

    2. MergedTranscript.merged(under:) reads the same transcript.jsonl files that JSONLRecorder writes. Tests confirm this: MergedAndRedactionTests and RecordingHandleResumeTests write through JSONLRecorder and read through merged(under:). Thus the finding applies. MergedTranscript cannot throw TranscriptTreeError.transcriptLineCorrupt, because that case needs a session ULID, and MergedTranscript reads directories that do not have ULID names (TranscriptEventSchemaTests uses "v1session" and "v2session"). Design: extract the shared decode loop into a new internal type TranscriptLineDecoding (new file). It drops a torn final line with a warning that names the file and the byte offset, and it throws a caller-supplied error for mid-file corruption. TranscriptTree maps that to TranscriptTreeError.transcriptLineCorrupt(session:file:). MergedTranscript gets a new public MergedTranscriptError.transcriptLineCorrupt(file:). All merged(under:) callers are tests, and no caller catches DecodingError, so the typed error is an addition, not a break.

    3. SessionFixture.directory in RecordingDurabilityTests.swift is written and never read. SessionFixture declares no Equatable or Hashable conformance, so the synthesized-conformance waiver does not apply. Fix: remove the member. A sweep of the file finds no other assign-only member.

    TDD plan: two new RED tests in RecordingDurabilityTests — merged(under:) drops a torn final line, and merged(under:) throws the typed error on mid-file corruption. The mutation blocks shared with the existing TranscriptTree tests move into fixture helpers, so the new tests do not copy them.
  timestamp: 2026-08-11T21:41:18.622745+00:00
- actor: claude-code
  id: 01kzsfgvx03bkhxtzfktdzz4j3
  text: |-
    All three review findings are fixed. The work was test-first: the two new tests failed with the raw DecodingError before the change, and passed after.

    1. Magic number (JSONLAppend.swift): the literal 0x0A is now the named internal constant `jsonlNewlineByte`, declared with a doc comment in JSONLAppend.swift. The writer (`appendJSONLine`) and the shared reader use the one constant. This was the only unnamed numeric literal in the file.

    2. MergedTranscript clone sibling (TranscriptTree.swift): the shared decode loop now lives in the new internal type `TranscriptLineDecoding` (Sources/FoundationModelsRouter/Recording/TranscriptLineDecoding.swift), so the two readers cannot drift. It drops a torn final line with a warning that names the file and the byte offset, and it throws a caller-supplied error for a corrupt non-final line. `TranscriptTree.decodeEvents` maps that to `TranscriptTreeError.transcriptLineCorrupt(session:file:)` and keeps its seq sort and its missing-file tolerance. `MergedTranscript.merged(under:)` maps it to the new public `MergedTranscriptError.transcriptLineCorrupt(file:)` (file only, no session id — MergedTranscript also reads directories that do not have ULID names, see TranscriptEventSchemaTests). `TranscriptTree` lost its private `newlineByte`, its private line splitter, and its now-unused logger and `import os`. The typed error is a public addition, not a break; every `merged(under:)` caller is a test and none catches DecodingError.

    3. Assign-only `directory` (RecordingDurabilityTests.swift): the member is removed from `SessionFixture`. The file has no other assign-only member. The two file-mutation blocks the new tests would have copied moved into the fixture helpers `tearFinalLine(of:keeping:)` and `corruptFirstTurnClose(of:)`, used by the old and the new tests.

    New tests: `merged(under:)` drops a torn final line (parameterized over kept-byte counts 1, 24, 60) and throws the typed error, naming the file, on mid-file corruption.

    Verification: `swift build` clean (only the accepted vendored mlx-swift "missing creator" warning). One full ungated `swift test` run: 832 tests in 79 suites passed with the one accepted BoundedWait known issue; the two hermetic gated-target wiring runs (27 and 24 tests) also passed; the env-gated real-model suites skipped by design.
  timestamp: 2026-08-11T22:36:35.616667+00:00
- actor: claude-code
  id: 01kzsfh183qfq0ftacck6pngbz
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Recording/JSONLAppend.swift, Sources/FoundationModelsRouter/Recording/TranscriptLineDecoding.swift (new), Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, Sources/FoundationModelsRouter/Recording/MergedTranscript.swift, Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift; all 3 findings flipped to [x]; swift build clean; one full swift test run: 832 tests in 79 suites passed (1 accepted BoundedWait known issue) plus the 27- and 24-test hermetic runs
    - next: /review
  timestamp: 2026-08-11T22:36:41.091830+00:00
position_column: doing
position_ordinal: '8180'
title: Define and test the recording durability policy
---
## Problem

The JSONL recorder appends through cached `FileHandle`s (Sources/FoundationModelsRouter/Recording/Sinks.swift:29-31) and never syncs. The crash story is undefined and untested:

1. A power cut or a kill can tear the final line of `transcript.jsonl`. That torn tail is the EXPECTED crash artifact — yet today one bad byte fails the entire tree load with a raw `DecodingError` that names no file (Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:429-431).
2. No flush or sync policy exists, so the window between "the turn completed" and "the record is durable" is whatever the OS decides.
3. The "lost run" tests never test durability: they close a router cleanly and reopen it; no write is ever interrupted.

## Proposed solution

1. Define the write policy and document it on the recorder: each appended line is written in one `write` call (already true — one line per append), and the handle is synced at a defined point. Decide the sync point: per append (safest, slowest), per turn close (the natural unit), or on a short timer. Recommend per turn close.
2. Tolerate the torn tail on load: when the LAST line of a `transcript.jsonl` fails to decode, drop it, log a warning naming the file and byte offset, and continue. A torn line is the crash artifact the policy expects.
3. Fail typed on mid-file corruption: a bad line that is NOT the last one throws a `TranscriptTreeError` naming the session and file (coordinates with task ^xky3j8w item 6 — that task adds the error context; this one adds the tail-tolerance policy).
4. Tests: write a valid log, truncate the final line at several byte offsets, and assert the tree loads with the turn-before state; corrupt a mid-file line and assert the typed error.

## Acceptance

- A truncated final line never fails a tree load; the loss is one event, reported in a warning.
- A corrupt mid-file line fails loudly with the session id and file path.
- The sync point is documented on `JSONLRecorder` and exercised by a test that kills nothing but asserts the sync call happens at the documented point.

## Review Findings (2026-08-11 16:28)

- [x] `Sources/FoundationModelsRouter/Recording/JSONLAppend.swift:102` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:480` — The change adds torn-final-line tolerance and mid-file corruption detection to `decodeEvents`, but per clone-siblings probe, a 0.90-similar transcript-reading implementation in MergedTranscript was left unchanged. If MergedTranscript reads the same transcript files that JSONLRecorder now produces with torn final lines, it must apply the same tolerance and error-handling logic to avoid inconsistent behavior — one reader tolerates torn lines, the other crashes. Verify whether MergedTranscript.decodeEvents or equivalent reads transcripts produced by JSONLRecorder; if so, apply the same torn-final-line drop (with warning) and mid-file corruption throw logic.
- [x] `Tests/FoundationModelsRouterTests/RecordingDurabilityTests.swift:34` — var.instance `directory` is assignOnlyProperty. #transcript