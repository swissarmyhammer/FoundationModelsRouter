---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzsybsqnthhfnmjthh1wddmr
  text: |-
    Research complete. Findings:

    - Only TranscriptTree decodes SessionSidecar today (rawNode, through SessionSidecar.read(in:)). MergedTranscript does not read sidecars. To make both readers gate, MergedTranscript must read the sidecar in each transcript file's directory before it decodes that file.
    - Design: a new file Recording/RecordingSchemaVersion.swift holds the version registry (v1, v2, current, implicit) and the typed error RecordingSchemaVersionError.recordingFromNewerRouter(directory:version:supported:).
    - The gate lives in SessionSidecar.read(in:). Every reader that decodes a sidecar goes through it. TranscriptTree.rawNode must rethrow the typed error. It must not map the typed error to sidecarUnreadable. Restore goes through TranscriptTree.load, so restore fails with the typed error.
    - Version meanings: v1 = initial event shape (flat text, toolCall kind, no entry payload). v2 = additive entry payloads, contentRemoved, and the SDK-mirror kinds. current = v2. A sidecar with no schemaVersion key decodes as implicit = v2. The implicit constant is frozen: a future bump of current must not move it.
    - Writers stamp through the SessionSidecar memberwise init default (schemaVersion = current). SessionSidecarWriter needs no change. withCompactionCount must carry schemaVersion through, or enrichment would reset it.
    - MergedTranscript keeps its tolerance for a transcript with no sidecar (existing tests build such trees by hand). The gate applies only when a sidecar decodes.
  timestamp: 2026-08-12T02:55:58.197857+00:00
- actor: claude-code
  id: 01kzt1hv4wse1mmwrxb6tqwb0k
  text: |-
    Implementation landed, TDD sequence complete.

    RED: six new tests, written first. The test build failed with "cannot find RecordingSchemaVersion in scope" — the correct failure for missing API.

    GREEN: all six tests pass in a filtered run.

    Changes:
    - New Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift: the version registry (v1, v2, current = v2, implicit = v2 frozen) and the typed error RecordingSchemaVersionError.recordingFromNewerRouter(directory:version:supported:). Each version constant documents what it added.
    - SessionSidecar: new schemaVersion Int field. The memberwise init defaults it to RecordingSchemaVersion.current, so every writer stamps it with no writer change. The decoder maps an absent key to implicit. withCompactionCount carries it through. The gate lives in SessionSidecar.read(in:): a decoded version newer than current throws the typed error.
    - TranscriptTree.rawNode: rethrows RecordingSchemaVersionError. It does not fold the typed error into sidecarUnreadable. Load and restore both reject a newer recording with the typed error.
    - MergedTranscript: new private checkSchemaVersion(besideTranscript:) consults the sidecar beside each transcript file before decode. A missing sidecar keeps the old tolerant behavior. An undecodable sidecar states no version, so the merge keeps its historical sidecar-free contract for that file (comment in code explains why).

    One test fix during GREEN: the merge test must canonicalize its temp directory (/var vs /private/var), because the typed error names the directory as file discovery spells it. TranscriptTreeTests already documents this same trap.
  timestamp: 2026-08-12T03:51:41.980747+00:00
- actor: claude-code
  id: 01kzt1jvkmh2e50p7zcfc23v2y
  text: |-
    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Recording/RecordingSchemaVersion.swift (new), Sources/FoundationModelsRouter/Recording/SessionSidecar.swift, Sources/FoundationModelsRouter/Recording/TranscriptTree.swift, Sources/FoundationModelsRouter/Recording/MergedTranscript.swift, Tests/FoundationModelsRouterTests/SessionSidecarTests.swift, Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift, Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift. One full `swift test` run: 854 tests in 81 suites passed (1 accepted known issue), 27 in 11 suites passed, 24 in 5 suites passed, zero failures.
    - next: /review
  timestamp: 2026-08-12T03:52:15.220975+00:00
- actor: claude-code
  id: 01kzt248jzg2t7jcpn3ra30ny6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD; the engine gave 1 confirmed finding on Tests/FoundationModelsRouterTests/TranscriptTreeTests.swift:184 (buildBranchingTree complexity); this helper was in the repository before this commit and the commit did not change it; the review skill drops findings that ask for a refactor of tests that were in the repository before the commit; 0 findings stay
    - next: none; the task is done
  timestamp: 2026-08-12T04:01:45.567674+00:00
- actor: claude-code
  id: 01kzt250wt2hkyzz2ze2c1eqd0
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 8 code files (1 new), RED to GREEN
    - test: green — swift test, 854 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: ec721b1
    - review: clean — 0 findings, scope HEAD~1..HEAD (1 engine finding waived per the written rule: it asked for a refactor of a test helper that existed before this commit)
    - result: the task is in done
  timestamp: 2026-08-12T04:02:10.458488+00:00
position_column: done
position_ordinal: ff9180
title: Stamp an explicit schema version on the sidecar and the event log
---
## Problem

Recording compatibility is purely by-optional-decoding: a new field decodes as `nil` on old lines, and nothing anywhere states which schema a file carries. That held for the v1-to-v2 transition. But the filed transcript work adds more shape: history ordinals (^6z1msg1), checkpoint changes (^h1008kb), unknown-case carriers (^9n7fna4), a configuration envelope. Without a version stamp, a future reader cannot distinguish "this field is nil because the recording predates it" from "this field is nil because it was legitimately absent" — the exact ambiguity that already forced the `contentRemoved` workaround (Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:17-23).

## Proposed solution

1. Add a `schemaVersion: Int` to `SessionSidecar` (one per session — sufficient granularity; per-line stamping would bloat every event for no reader benefit). Absent decodes as the current implicit version.
2. Define the version registry in one place: an enum or constant list in the Recording module, each version documented with what it added.
3. Readers gate on it: a version NEWER than the reader knows produces a typed "recording from a newer router" error instead of silent misreads; an older version keeps decoding by the additive rule, as today.
4. Writers stamp the current version on every new sidecar.
5. Land this BEFORE or WITH the first schema-touching task above, so the next shape change is born versioned.

## Acceptance

- New recordings carry the version; old recordings decode as the implicit version.
- A fabricated future-version sidecar fails restore with the typed error.
- The version registry documents every version and its additions. #transcript