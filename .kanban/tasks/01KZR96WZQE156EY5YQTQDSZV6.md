---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzwdqgy6zhs18mhqthb6z3zr
  text: |-
    Research complete. Findings:

    - `SessionEvent` has no `Codable` conformance, so "keep cases decodable" resolves to "keep consumers compiling". The plan is to add `output: [SegmentPayload]?` as a fourth associated value on `toolStatus`.
    - `ToolCallEntry` is top-level in Sources/FoundationModelsRouter/Session/SessionProjection.swift with a synthesized internal memberwise init. A new `public var output: [SegmentPayload]? = nil` keeps all construction sites valid.
    - Live emit site: `RoutedSessionActorRecording.emitSessionEvents` — the `.toolOutput` arm has `partial.entry.segments` available (the same `TranscriptEntryMapper` mapping the seed path uses), so live and seeded rows will carry equal payloads, segment ids included. The seeding acceptance test compares full row equality between the two paths and will police this.
    - Seed site: `SessionProjection.transcriptRows(from:)` `.toolOutput` arm — `payload.segments` goes through `updateToolCallRow`, which gains an `output` parameter.
    - `TurnOutcomeFold` consumes the same event and shares `ToolCallEntry`; it gets the same pass-through.
    - Consumers to update for the new case arity: SessionProjection, TurnOutcome, RoutedSessionActorRecording (3 emit sites), Examples/CompactionDemo (a built executable target), and test matchers in SessionEventStreamTests, SessionProjectionTests, ToolInvocationLivenessTests, ScriptedToolTurnComparisonTests, RealToolTurnComparisonTests.
    - DocC: every ``toolStatus(id:status:summary:)`` and ``updateToolCallRow(id:status:summary:in:)`` symbol link across Sources must move to the new labels.
    - Test fixtures: `Transcript.StructuredSegment(id:schemaName:content:)` and the per-file private `PersistableCustomSegment` conformer pattern (see TranscriptEntryMapperTests) give deterministic segment ids for exact-equality assertions.

    TDD plan: phase 1 adds the vocabulary only (event case + entry field, consumers drop the value, emitters pass nil) plus the new tests — red. Phase 2 wires population on both paths — green, verified by the single full `swift test` run.
  timestamp: 2026-08-13T02:02:59.910563+00:00
- actor: claude-code
  id: 01kzwnh30kbdp6ys7s0cmqtmep
  text: |-
    Implementation complete, TDD red then green.

    What changed:
    - `ToolCallEntry` (Sources/FoundationModelsRouter/Session/SessionProjection.swift) has a new documented field `output: [SegmentPayload]?`. The default is `nil`, so all construction sites stay valid. `summary` stays the flattened text.
    - `SessionEvent.toolStatus` (Sources/FoundationModelsRouter/Session/SessionEvent.swift) has a new fourth associated value `output: [SegmentPayload]?`. `SessionEvent` has no `Codable` conformance, so no coding change was necessary. All consumers now compile with the new arity: SessionProjection, TurnOutcomeFold, RoutedSessionActorRecording (3 emit sites), Examples/CompactionDemo, and the test matchers.
    - Live path: `RoutedSessionActorRecording.emitSessionEvents` emits `output: entry.segments` on the completed status. Running and failed statuses carry `output: nil`.
    - Shared row update: `updateToolCallRow(id:status:summary:output:in:)` writes the output onto the row — the one body for the live path and the seed path.
    - Seed path: `transcriptRows(from:)` passes `payload.segments` for each `.toolOutput` entry, so live rows and seeded rows carry equal data. The existing acceptance test compares the two paths by full row equality and stays green.
    - `TurnOutcomeFold` passes `output` through to `TurnOutcome.toolCalls`, so the shared `ToolCallEntry` type stays truthful on that surface too.
    - DocC sweep: every symbol link moved from `toolStatus(id:status:summary:)` to `toolStatus(id:status:summary:output:)`, and from `updateToolCallRow(id:status:summary:in:)` to `updateToolCallRow(id:status:summary:output:in:)`, across Sources, Tests, and compaction_plan.md.

    Tests:
    - New shared fixture Tests/FoundationModelsRouterTests/Helpers/CustomSegmentFixtures.swift (`TestNote`/`TestNoteSegment`) for `.custom` segments.
    - Live path: SessionEventStreamTests `completedStatusCarriesFullOutputSegments` (text + structure + custom through a real diff; schema name and content JSON asserted intact) and updated exact-sequence tests with deterministic segment ids; SessionProjectionTests `completedStatusCarriesFullOutputSegmentsOnTheRow`.
    - Seeded path: SessionProjectionSeedingTests `seededOutputCarriesFullSegments` (text + structure + custom; summary stays the flattened text) plus output assertions on the grouped-rows test.
    - TurnOutcomeTests: output pass-through assertion on the real scripted turn.

    TDD evidence: `swift test --filter` red check showed the 3 new tests fail (output was nil) before the wiring. One ungated full `swift test` after the wiring: all targets green, no failing-target trailer, final summary passed (969 tests listed across targets). One `swift build --build-tests` shows zero compiler warnings; the only "warning" line is the pre-existing SwiftPM build-graph notice about the vendored mlx bundle.

    ### implement — changed
    - evidence: 10 source files, 8 test files (1 new fixture), Examples/CompactionDemo/main.swift, compaction_plan.md; one red filtered run (3 failures as expected), one full `swift test` green
    - next: /review
  timestamp: 2026-08-13T04:19:17.651220+00:00
- actor: claude-code
  id: 01kzwp3kdem2ahzjnrbt7qbjx0
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (9c46dfa) — 0 findings, 0 confirmed, 1 refuted
    - next: task moved to done
  timestamp: 2026-08-13T04:29:24.270684+00:00
- actor: claude-code
  id: 01kzwp473hhka8sfbt79e4spew
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 10 source files, 8 test files, compaction_plan.md; one full `swift test` run green, 969 tests, zero warnings
    - commit: 9c46dfa — 23 files
    - review: clean — 0 findings
    - next: none — task is done
  timestamp: 2026-08-13T04:29:44.433639+00:00
depends_on:
- 01KZR96MYJ1M1XGB8855AKY6XR
position_column: done
position_ordinal: ffa180
title: Carry full tool output segments in ToolCallEntry
---
## Problem

`SessionProjection.ToolCallEntry.summary` holds flattened text only — the `summary` string from `SessionEvent.toolStatus(id:status:summary:)`. The `.toolOutput` entry's real segments are lost on the way: `.structure` (schema-named JSON), `.attachment`, and `.custom` segments never reach the projection. A UI cannot render a structured tool result, show an attachment, or display a custom segment. It can only show a flat string.

## Proposed solution

1. Add an output field to `ToolCallEntry`, for example `output: [SegmentPayload]?`. `SegmentPayload` (Sources/FoundationModelsRouter/Recording/TranscriptEntryPayload.swift:155) is already `Sendable`, `Codable`, and `Equatable`, and covers all four segment kinds. Populate it when the call completes. Keep `summary` as the flat-text convenience.
2. Extend the event vocabulary so the segments can travel: let `SessionEvent.toolStatus` carry the segments (or add a payload case). Keep the current cases decodable and the current consumers working.
3. Make the cold-seed path (task ^5aky6xr, "Seed SessionProjection from a cold Transcript") fill the same field from the `.toolOutput` entry's segments, so live and seeded rows carry equal data.

## Acceptance

- A completed tool call with a `.structure` segment must surface that segment in the projection row, with its schema name and content JSON intact.
- `summary` must stay equal to the flattened text it carries today.
- Tests must cover text, structure, and custom segment outputs on both the live path and the seeded path. #projection