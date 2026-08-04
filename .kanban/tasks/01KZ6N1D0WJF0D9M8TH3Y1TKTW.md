---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz76vf1bqmz4vc7vjgqbjfww
  text: |-
    Research findings (picked up, moved to doing):

    - Already done in tree (landed during ^3g930c4 SessionMailbox work): `CustomSegmentRegistry.routerDefault` registers `OperationEventSegment` (Recording/CustomSegmentRegistry.swift), and `RoutedSessionActor.close()` journals swept terminal events as `.toolOutput` entries carrying `OperationEventSegment`.
    - Still open: (1) doc at Session/OperationEventSegment.swift still says round-trips work "once an integrator registers it" — must state routerDefault pre-registration instead; (2) the crash-edge `.lost` manufacture in Recording/SessionTreeRestoration.swift's `restore(_ node:)` closure; (3) tests.
    - Scan input: `tree.effectiveEntryEvents(forSession:)` (already computed in the closure for `restoredUsageState`) — walk each event's `entry?.segments`, match `.custom` payloads with `typeDiscriminator == OperationEventSegment.typeDiscriminator`, decode `contentJSON` as `OperationEvent` (pattern: `compactionSegmentContent(in:)` in TranscriptReconstruction.swift). Non-terminal kinds = `.progress`, `.elicitation`; orphan = correlationID with no `.completed` anywhere in stream. Manufacture one `.completed` with `outcome: .lost` per orphaned correlationID (tool/op/detail from newest non-terminal event) and `await outbox.post(...)` on the node's fresh outbox — requires making the recursive `restore(_:)` closure `async`.
    - Journaling path for fixtures: posting to a session's outbox then driving `respond(to:)` drains events onto the recorded `.prompt` entry as OperationEventSegments (verified in PendingEventInjectionTests), so tests can build orphaned/completed runs with StubSessionBackend + two routers sharing a recordings dir (pattern: SessionTreeRestorationToolWiringTests).
    - Plan: TDD — new Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift with 4 tests (default-registry round trip, one orphan → one .lost, completed run → none, two orphans → two .lost with distinct correlationIDs), watch them fail, then implement.
  timestamp: 2026-08-04T20:18:45.931467+00:00
- actor: claude-code
  id: 01kz78yn1eqvdfws18yh2nxe1a
  text: |-
    Implementation landed (TDD, two passes).

    Pass 1 (core work):
    - Recording/SessionTreeRestoration.swift: per-node `restore(_:)` closure made `async`; after computing the node's effective entry events it now runs `TranscriptTree.lostRunTerminalEvents(in:)` and posts each manufactured `.completed`/`.lost` to the node's fresh outbox (the next turn's drain journals it durably). New `TranscriptTree` extension in the same file: `lostRunTerminalEvents(in:)` + private `operationEvents(in:)` (decodes OperationEventSegment payloads from `entry.segments`, pattern of `compactionSegmentContent(in:)`). `restoreSessionTree` doc gained an "Orphaned journaled runs come back `.lost`" section.
    - Session/OperationEventSegment.swift: doc no longer assigns registration to the integrator — states routerDefault pre-registration (the registration itself had already landed with ^3g930c4).
    - New Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift (watched red first): default-registry round trip, orphaned .progress → one .lost, completed run → none, two orphans → two .lost with distinct correlationIDs.

    Pass 2 (double-check verdict REVISE, all 5 findings implemented, each red-then-green where behavioral):
    1. Orphan detection now keyed by `(tool, correlationID)` (`RunKey`), matching SessionOutbox.post's coalescing identity — correlationIDs are tool-assigned and only unique per tool. Test: one tool's .completed does not suppress another tool's orphan sharing the id.
    2. Manufactured detail for an orphaned elicitation is `elicitation.message ?? detail`; elicitation test fixture rebuilt to the production shape (`detail: ""`, real ElicitationRequest) instead of one violating OperationEvent's elicitation invariant.
    3. Per-node fork rule decided and documented in the restoreSessionTree doc: scan is per node over that node's own effective view — an ancestor's orphan yields one .lost on every node whose inherited prefix carries it, and a run completed by the parent after the fork cut is .lost from the fork's view. Two fork tests pin both consequences.
    4. Manufactured detail bounded to trailing `SessionMailbox.terminalDetailTailLimit` chars — the same cap sweep()'s synthesized terminal applies. Test with an oversized progress detail.
    5. Order-sensitive "newest event is non-terminal" wording replaced everywhere (public doc, in-body comment, helper doc, test-suite doc) with the implemented rule: any non-terminal event with no .completed for the pair anywhere in the stream.

    Verification: `swift test` full run green — 673 + 18 + 12 tests across the three targets, zero failures; only pre-existing mlx bundle build warning. Callers of restoreSessionTree (public signature unchanged) all still pass. Session was interrupted once by a session limit mid double-check; working tree verified intact on resume.
  timestamp: 2026-08-04T20:55:27.534462+00:00
- actor: claude-code
  id: 01kz78ysqwyhr2xfb0sems260j
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift, Sources/FoundationModelsRouter/Session/OperationEventSegment.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift (new, 9 tests); swift test green 673+18+12, 0 failures
    - next: /review
  timestamp: 2026-08-04T20:55:32.348302+00:00
depends_on:
- 01KZ6MY4E1H1RG9SCY8YR4A48H
- 01KZ6N038H8VC4C5CXQXYKSGNS
position_column: doing
position_ordinal: '80'
title: '[Router] Register OperationEventSegment; manufacture .lost on restore'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"Elevation" crash-edge paragraph: "Restoration marks journaled runs that have no terminal event as `.lost`." Research found the prerequisite gap this task closes.

## What
- `Recording/CustomSegmentRegistry.swift`: `routerDefault` (lines 168-172) registers only `CompactionSegment` today, so every default-argument restore path (`restoreSessionTree`, `effectiveTranscript(forSession:registry:)`, `RoutedModel.makeLanguageModel(resuming:registry:)`) throws `unregisteredCustomSegmentType` on any transcript containing a recorded operation event. Add `OperationEventSegment` to `routerDefault` and fix the doc at `Session/OperationEventSegment.swift:25-26` that currently assigns registration to the integrator.
- `Recording/SessionTreeRestoration.swift`: in the per-node `restore(_ node:)` closure (lines 250-320), scan the node's effective event stream for journaled runs that have a non-terminal event (`.progress` or elicitation kind) with no matching `.completed` for the same `correlationID`. For each, manufacture a terminal `.completed` event with outcome `.lost` and post it to the restored session's outbox, so the durable record has no holes and the model learns the run died with the crashed process. This is the only place `.lost` is manufactured outside an MCP transport drop.
- The teardown sweep (SessionMailbox task) handles the orderly-shutdown case; this task covers only the crash edge where the memory-only mailbox is gone.

## Acceptance Criteria
- [ ] Restoring a recorded transcript that contains `OperationEventSegment`s succeeds with the default registry (regression for the `unregisteredCustomSegmentType` throw)
- [ ] Restoring a transcript whose last events include a `.progress` with no matching `.completed` produces exactly one manufactured `.completed` with outcome `.lost` for that `correlationID`, delivered via the restored session's outbox
- [ ] A transcript whose runs all completed produces no manufactured events
- [ ] `swift test` green

## Tests
- [ ] Extend `Tests/FoundationModelsRouterTests/` restoration coverage (pattern from `SessionTreeRestorationToolWiringTests.swift`): default-registry round trip with event segments; orphaned-run → `.lost` manufacture; completed-run → no manufacture; two orphaned runs → two `.lost` events with distinct correlationIDs
- [ ] `swift test` green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first