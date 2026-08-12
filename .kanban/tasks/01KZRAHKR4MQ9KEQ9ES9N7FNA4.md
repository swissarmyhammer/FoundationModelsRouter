---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzt9a1k8gz8ndcwjscmy6ddh
  text: |-
    Research done. Design decisions:

    1. Carriers. Add `SegmentPayload.unknown(id:description:)` for segments. Add `TranscriptEvent.Kind.unknown` for entries. At record time, an unknown entry payload stores the entry id plus one `.unknown` segment that holds the SDK value's `description` text. Both `Transcript.Entry` and `Transcript.Segment` supply `id: String` and `description` (verified in the macOS SDK swiftinterface: both are `Identifiable` and `CustomStringConvertible`).
    2. Schema version. The carriers stay in v2. Reason: this build can write a carrier only when it runs on a future OS that adds an SDK case. On the current SDK, recordings do not change at all. A bump of `current` to v3 makes every old reader refuse every new recording, to guard against a carrier that cannot occur on the current SDK. The known gap: an old v2 reader that meets a carrier-bearing recording gets a decode error, not the typed newer-router refusal. That trade is deliberate and is recorded in the v2 doc. When a future SDK case becomes known and the mapper maps it as a real kind, THAT change is the shape change that must be born versioned.
    3. Rebuild. An `.unknown` segment becomes a `.text` segment that carries the description. A `.unknown` kind becomes a text-only `.response` entry — `.response` is the one segments-carrying entry case whose initializer needs nothing beyond id and segments (assetIDs can be empty). Reconstruction stays total; `contentRemoved` and `missingRequiredField` refusals apply as for every other kind.
    4. Warnings. Log through `makeModuleLogger(category: "Recording")` at record time (naming the unrecognized case via `Mirror`) and at rebuild time (naming the degradation). The test reads the warning back with `OSLogStore(scope: .currentProcessIdentifier)`, since the record-time arm is unreachable on the current SDK.
    5. Exhaustive switches to update: `TranscriptTree.isEntryKind` (`.unknown` is an entry kind), `TranscriptEntryMapper.entry(from:kind:)`, `RoutedSessionActorRecording.emitSessionEvents` (`.unknown` yields no session event). Invariant sites in the payload: `contentByteCount`, `strippingContent()`, `redacted(with:)` all handle the new case (description counts as content, is stripped, and is redacted).
    6. Docs: mapper type doc gains the degradation entry; plan.md "Honest fidelity scope" gains the unknown-case paragraph; `RecordingSchemaVersion.v2` doc records the version decision.
  timestamp: 2026-08-12T06:07:15.048277+00:00
- actor: claude-code
  id: 01kztdjfc7xc1aqev2n2phns2m
  text: |-
    Implementation done, TDD (RED first: the new schema tests failed to compile with "type 'SegmentPayload' has no member 'unknown'", and the decode-path test had no `unknown` type to decode; then GREEN).

    What changed:
    - `TranscriptEvent.Kind` gains `unknown`; `SegmentPayload` gains `unknown(id:description:)` with encode/decode arms, and the new case is handled in `contentByteCount` (description counts as content), `strippingContent()` (description blanked), and `redacted(with:)` (description is a redaction site).
    - `TranscriptEntryMapper`: both `fatalError` arms are gone. Record time maps an unknown entry to kind `.unknown` with one `.unknown` segment (entry id + `description` text) and an unknown segment to the `.unknown` carrier, each with a warning that names the case via `Mirror` (public privacy; content stays private). Rebuild time turns an `.unknown` segment into a `.text` segment and an `.unknown` kind into a text-only `.response` entry, each with a warning. `contentRemoved` and `missingRequiredField` refusals apply as for every other kind.
    - `TranscriptTree.isEntryKind`: `.unknown` is an entry kind, so reconstruction sees it. `RoutedSessionActorRecording.emitSessionEvents`: `.unknown` yields no session event.
    - Version decision recorded in the `RecordingSchemaVersion.v2` doc: carriers land within v2; reasoning and the known old-reader decode-error limit are stated there and in an earlier comment here.
    - plan.md "Honest fidelity scope" gains the unknown-case paragraph; the mapper type doc lists the degradation.
    - Tests: 4 new schema tests (decode from recorded JSON, round-trip, strip/redact, Kind round-trip) and 2 new mapper tests that assert the text degradation AND read the logged warning back through `OSLogStore(scope: .currentProcessIdentifier)` — a real assertion, not a comment. Old-recording tests (v1 line, legacy toolCall, bogus segment type still throws) all still pass.

    Acceptance check: no `fatalError` remains in the mapper (grep count 0); the simulated unknown segment records without crash, rebuilds as text, and the warning is asserted; old recordings still decode.

    ### implement — changed
    - evidence: 8 files — Sources/FoundationModelsRouter/Recording/{TranscriptEvent,TranscriptEntryPayload,TranscriptEntryMapper,TranscriptTree,RecordingSchemaVersion}.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift, Tests/FoundationModelsRouterTests/{TranscriptEventSchemaTests,TranscriptEntryMapperTests}.swift, plus plan.md; `swift test` = 863+27+24 tests passed, 0 failures (1 known issue: the accepted BoundedWait one)
    - next: /review
  timestamp: 2026-08-12T07:21:45.607706+00:00
- actor: claude-code
  id: 01kzte26rvtt0rgjmxg8cd9nzb
  text: |-
    ### review — findings
    - evidence: 1 confirmed finding — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:356 (review sha HEAD~1..HEAD; counts: 1 finding, 1 confirmed, 0 refuted)
    - next: put the .unknown kind into the array in newKindCasesRoundTrip, remove the unknownKindRoundTrips function, and check the item in the findings list
  timestamp: 2026-08-12T07:30:21.083653+00:00
- actor: claude-code
  id: 01kzte3dj3c0gay8vb8d4wkjex
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 9 files, both fatalError arms replaced with unknown-case carriers
    - test: green — swift test, 863 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 2818890
    - review: findings — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:356 (unknownKindRoundTrips duplicates newKindCasesRoundTrip; add .unknown to the kind array and remove the new function)
  timestamp: 2026-08-12T07:31:00.803739+00:00
- actor: claude-code
  id: 01kztfhb0hz62wr0byy5nmzqqd
  text: |-
    Finding fixed. The kind array in newKindCasesRoundTrip now contains .unknown, and the test name gives the four kinds. The duplicate function unknownKindRoundTrips is removed.

    Sweep for the same cause: the schema test file has only one parameterized test (newKindCasesRoundTrip). The three other new tests in that file (carrier decode, carrier round trip, strip and redact) have no parameterized counterpart and follow the one-function-for-each-segment-kind pattern of the file. The mapper test file has no parameterized test, so the two new mapper tests cannot be duplicates. No other duplicate found.

    The finding item is set to done. The tags stay [transcript] and the description keeps its structure (verified after the update).
  timestamp: 2026-08-12T07:56:05.521182+00:00
- actor: claude-code
  id: 01kztfhjq8nf5bg0mjferqbpjt
  text: |-
    ### implement — changed
    - evidence: 1 file — Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift; swift build --build-tests OK; swift test = 862 + 27 + 24 tests passed, 0 failures (1 known issue: the accepted BoundedWait one; the accepted missing-creator warning)
    - next: /review
  timestamp: 2026-08-12T07:56:13.416802+00:00
- actor: claude-code
  id: 01kztfqfcz5w8xyew4nx7cdd43
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD — 0 findings (8 validators, 0 failed); the one prior finding is checked and fixed in commit 4566993
    - next: none; the task is done
  timestamp: 2026-08-12T07:59:26.623485+00:00
- actor: claude-code
  id: 01kztfr8q1csky8pcqadkbsm11
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file, the duplicate test folded into the parameterized round-trip test
    - test: green — swift test, 862 + 27 + 24 passed, 1 accepted known issue (BoundedWait); the one green run in the implement step is the test evidence
    - commit: 4566993
    - review: clean — 0 findings, scope HEAD~1..HEAD; the prior finding is checked
    - result: the task is in done
  timestamp: 2026-08-12T07:59:52.545162+00:00
depends_on:
- 01KZRB8W3SADG2MHP3B2GTD3DM
position_column: done
position_ordinal: ff9380
title: Replace the mapper's fatalError arms with typed degradation for unknown SDK cases
---
## Problem

Both `@unknown default` arms in the entry mapper call `fatalError` — one for a future `Transcript.Entry` case (Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift:145-152) and one for a future `Transcript.Segment` case (:365-368). The mapping is complete for the macOS 27 SDK only. The day the SDK adds a seventh entry case or a fifth segment case, the router does not degrade — it crashes the host process at record time, in the middle of a user's turn. A recording library must never turn an SDK addition into a crash.

## Proposed solution

1. Add an explicit unknown-carrier to the payload schema: for segments, an `unknown` case that stores the segment's `id` and a best-effort text rendering (the SDK segment's `description`); for entries, an `unknown` payload kind that stores the entry's `id` and flattened text. Both are additive schema changes, mirroring the v1-to-v2 additive rule the schema already follows.
2. At record time, map an unknown case into that carrier and log a warning naming the unrecognized case — the turn completes, the recording keeps its shape, the content is preserved as text.
3. At rebuild time, an unknown carrier becomes a `.text` segment (or a text-only entry) — degraded, visible, and never a crash. Reconstruction stays total.
4. Document the degradation in the mapper doc and in plan.md's fidelity section: unknown future cases record as text, with their exact structure lost until the mapper learns the new case.

## Acceptance

- No `fatalError` remains in the mapper.
- A test simulates an unknown segment (via the carrier's own decode path, since a real unknown SDK case cannot be constructed) and asserts: recorded without crash, rebuilt as the documented text degradation, warning logged.
- Old recordings still decode (additive schema rule holds).

## Review Findings (2026-08-12 02:23)

- [x] `Tests/FoundationModelsRouterTests/TranscriptEventSchemaTests.swift:356` — unknownKindRoundTrips duplicates the test logic from newKindCasesRoundTrip (line 18-32). Both create a TranscriptEvent, encode/decode it through Codable, and assert roundtrip equality. The .unknown kind should have been added to the array at line 20 rather than creating a parallel test function. Add `.unknown` to the kind array in newKindCasesRoundTrip at line 20: `for kind: TranscriptEvent.Kind in [.instructions, .toolCalls, .reasoning, .unknown]`, update the test comment to reflect this, and remove the new unknownKindRoundTrips test function entirely (lines 356-369). #transcript