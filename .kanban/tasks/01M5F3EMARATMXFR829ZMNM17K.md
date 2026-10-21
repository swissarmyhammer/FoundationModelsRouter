---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f6ra3pn8rpepmgw8yqdqvz
  text: |-
    Implementation (uncommitted, in the Router working tree):
    - Sources/FoundationModelsRouter/Recording/SessionIndex.swift — public SessionIndexRecord, SessionIndexWarning, SessionIndexError, SessionIndexReadResult, SessionIndex (append, read, removeRecords(sessionId:), rebuild(cwd:), .gitattributes materialization). Doc comments say Router owns the record (D72). Uses Router's `sessionSidecarFileName`; the module-level `transcriptFileName` in TranscriptTree.swift went from private to internal so the index reuses it.
    - Sources/FoundationModelsRouter/Recording/JSONLines.swift — internal copy of the ACPAgent helper. `appendJSONLine` (JSONLAppend.swift) does not give the same contract: it logs and drops failures, the index throws. Newline byte reuses `jsonlNewlineByte`.
    - RouterTelemetry.LogCategory gained `sessionIndex` ("FoundationModelsRouter.SessionIndex") for the torn-line warning (ACPAgent used ACPAgentTelemetry .transcripts).
    - Tests: SessionIndexTests.swift (16 tests: the 13 copied, with ACPAgentTelemetry -> RouterTelemetry and the logger-label test pointed at the new category; plus 3 ACPAgent byte-compat tests: old-format file reads to same records, torn final line warns, append writes identical bytes), RouterImportsNoACPTests.swift (2 tests). Shared helper Helpers/LibrarySourceFiles.swift; UpstreamAsksDocumentTests now calls it instead of its own copy.
    - Router: `swift build --build-tests` clean (only the pre-existing build-system note "missing creator for mutated node ... mlx-swift_Cmlx.bundle"); full `swift test`: 1959 tests / 244 suites passed with 9 known issues, plus 27 and 19 in the other targets.

    ACPAgent check (scratch clone of FoundationModelsACPAgent at cb92ec8, `swift package edit` FoundationModelsRouter -> this working tree and FoundationModelsExtras -> bd34b20): the ACPAgent library target compiles, but its test target does not:
    - Tests/FoundationModelsACPAgentTests/TranscriptRecordingFixtures.swift:138 — 'SessionIndex' is ambiguous for type lookup in this context
    - Tests/FoundationModelsACPAgentTests/TranscriptStoreTests.swift:53 — 'SessionIndex' is ambiguous for type lookup in this context
    (plus follow-on "failed to produce diagnostic" errors at TranscriptRecordingFixtures.swift:181 and TranscriptStoreTests.swift:142). These files import both FoundationModelsRouter and @testable FoundationModelsACPAgent.
  timestamp: 2026-10-21T12:25:08.982699+00:00
- actor: claude-code
  id: 01m5f6rcggfkqewwpms02qnbsx
  text: |-
    ### implement — stuck
    - evidence: Router green (swift test: 1959 tests passed, 9 known issues; build clean). ACPAgent test target fails to compile against this Router: 'SessionIndex' is ambiguous in TranscriptRecordingFixtures.swift:138 and TranscriptStoreTests.swift:53.
    - blocker: the card says stop and ask when a name is ambiguous. Decision needed: (a) do ACPA-14 first (remove the ACPAgent copies), or (b) qualify the names in ACPAgent (e.g. FoundationModelsACPAgent.SessionIndex in its tests).
    - state: not committed; the Router changes are in the working tree. ^k176prd and later cards not started.
  timestamp: 2026-10-21T12:25:11.440840+00:00
- actor: claude-code
  id: 01m5f78vg3rzvp75v6a848vybg
  text: |-
    ### decision — user (2026-10-21)
    - Wait for ACPA-14. The finished work is parked on branch router-3-session-index (29ae4767) and is not merged to main. Merge it once the ACPAgent session's ACPA-14 removes ACPAgent's own SessionIndex/ProjectRegistry. Until then, ACPAgent's test target sees SessionIndex as ambiguous (TranscriptRecordingFixtures.swift:138, TranscriptStoreTests.swift:53). ^k176prd waits too.
  timestamp: 2026-10-21T12:34:11.075341+00:00
position_column: review
position_ordinal: '8480'
title: 'ROUTER-3: Copy SessionIndex (sessions.jsonl) from ACPAgent Transcripts/ into Router Recording/'
---
## Goal
Router owns the record of past sessions (D72). This card makes `SessionIndex` (`sessions.jsonl`) a public Router type with the same file name and the same line format, so the files on a user's disk stay valid. `ProjectRegistry` is the next card.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-3-session-directory (second paragraph)
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.2 ("The record of past sessions moves into Router")
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 14 (ROUTER-3, ACPA-14)

## Why no depends_on
The spec puts ROUTER-3 after ROUTER-1 and EXTRAS-3. This card is a pure copy of existing ACPAgent code into Router: it uses no `SessionFacts` and no Extras `Sessions/` type, so it can start now. The directory cards that read it keep the spec order.

## What
- Copy (do not delete the original; ACPA-14 in the ACPAgent repo removes it) `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Sources/FoundationModelsACPAgent/Transcripts/SessionIndex.swift` to `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/SessionIndex.swift`, as public Router types: `SessionIndexRecord`, `SessionIndexWarning`, `SessionIndexError`, `SessionIndexReadResult`, `SessionIndex` (`append`, `read`, `removeRecords(sessionId:)`, `rebuild(cwd:)`, the `.gitattributes` materialization).
- Copy the ACPAgent `Transcripts/JSONLines.swift` helper as internal `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Recording/JSONLines.swift`, or use Router's `Recording/JSONLAppend.swift` (`appendJSONLine`) where it gives the same bytes. The encoded bytes of a record must not change.
- Use Router's `sessionSidecarFileName` (`Recording/SessionSidecar.swift`) in place of the copy `SessionIndex.sidecarFileName`.
- Copy `/Users/wballard/github/swissarmyhammer/FoundationModelsACPAgent/Tests/FoundationModelsACPAgentTests/SessionIndexTests.swift` into Router's test target (the ACPAgent copy stays until ACPA-14).
- Name overlap: ACPAgent imports `FoundationModelsRouter` and also declares public `SessionIndex*` types; its `SessionIndexTests.swift` imports both modules. Check that ACPAgent still builds and tests against this Router revision, and write the result on this card. If a name is ambiguous there, stop and ask (options: ACPA-14 first, or qualify the names in ACPAgent).

## Subtasks
- [ ] Failing test first: the copied `SessionIndexTests` fail to compile in Router until the type exists.
- [ ] Compatibility test: a `sessions.jsonl` literal written byte-for-byte as the ACPAgent code writes it today reads back to the expected records, and `append` of the same record writes the same bytes.
- [ ] Add the public types in `Recording/`, with doc comments that say Router owns the record (D72).
- [ ] Source-scan test: no file under `Sources/FoundationModelsRouter` imports a `FoundationModelsACP` module (there is no such check today).
- [ ] Build and test FoundationModelsACPAgent against this Router (local package override, `swift package edit` or a path dependency in a scratch checkout); record the result on this card.

## Acceptance Criteria
- [ ] The copied `SessionIndexTests` pass in `FoundationModelsRouterTests` with no change to their assertions other than imports.
- [ ] A file in the old ACPAgent format reads to the same records; a torn final line gives `SessionIndexWarning.tornFinalLine`.
- [ ] `append` writes the same bytes as the ACPAgent version for the same record.
- [ ] The ACP import scan test passes.
- [ ] The ACPAgent build and test result against this Router is recorded on the card.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionIndexTests.swift`
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/RouterImportsNoACPTests.swift`
- [ ] `swift test --filter "SessionIndex|RouterImportsNoACP"` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording #cross-repo
