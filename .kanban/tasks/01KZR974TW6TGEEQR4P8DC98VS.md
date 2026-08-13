---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzwpws4wdra5hgh8rjeh2k9c
  text: |-
    Research done. Facts found:

    1. Live row order and seeded row order are not equal. Text rows go into the transcript when the text streams. Reasoning rows and tool-call rows go in at diff time. Thus the answer text row can come before the tool rows in the live projection.
    2. The `entryRecorded` closes come in transcript order (see `emitSessionEvents` in RoutedSessionActorRecording.swift). This order is the shared signal. The grouped view can sort rows into transcript order with it on both paths.
    3. `textReset` tells the live projection which text row is superseded. The cold path can find the same rows with a structural rule: a text row is superseded when a later plain response entry starts in the same turn (scope resets at each `.prompt` entry; a compaction boundary response does not count, because the fold does not stream).

    Plan:
    - Add two private bookkeeping fields to SessionProjection: the superseded text row ids, and the recorded-entry ordinals. `apply(_:)` keeps its full observable behavior (phase, rows, counters); it only records the two facts.
    - Add a public computed `groupedRows` that (a) sorts rows into canonical entry order, (b) attaches the adjacent run of reasoning rows and superseded text rows to the next tool-call group. Each group gets its identity from the call's SDK id.
    - `seed(from:)` fills the same bookkeeping from the cold entries, so grouped views agree between live and seeded paths.
    - Known limit, documented: a turn that ends with no final answer can let its trailing context attach to the next turn's first call. A completed turn always seals its run with the answer text row.
  timestamp: 2026-08-13T04:43:09.340084+00:00
- actor: claude-code
  id: 01kzwsr1ntbhcke4x4t2h51zsx
  text: |-
    Implementation landed, TDD (red first, then green).

    What changed:
    - `SessionProjection` gets a public computed `groupedRows: [GroupedRow]`, with two new nested public types: `GroupedRow` (`.row` or `.toolCallGroup`) and `ToolCallGroup` (the call row plus its `context` rows). A group's `id` is the call's SDK id.
    - The rule: rows first sort into canonical (transcript) order through the recorded-entry ordinals that `entryRecorded` closes supply — both paths share that order. Then the contiguous run of reasoning rows and superseded text rows immediately before a tool-call row attaches to that call's group. The final answer, compaction rows, and trailing context stay top-level.
    - Two private bookkeeping fields: `supersededTextRowIds` (live: marked at `textReset`, carried across the adopt-id transition; seeded: the structural mirror `supersededTextEntryIds(in:)`) and `recordedEntryOrdinals`. `apply(_:)` keeps its full observable behavior — phase, rows, counters unchanged, all prior tests still green.
    - `seed(from:)` installs the same bookkeeping from the cold entries, so `seeded.groupedRows == live.groupedRows`.
    - Documented limit: rows carry no turn marker, so a turn that ends with no answer text can let its trailing context attach to the next turn's first call. A completed turn always seals its run.

    Tests:
    - SessionProjectionTests: four new grouped-view tests (acceptance shape over live event order, two concurrent same-name calls with distinct group ids, trailing reasoning + answer top-level, plain turn).
    - SessionProjectionSeedingTests: a new seeded-vs-live grouped equality unit test, and the restore acceptance test now also plays a narrated script and asserts `seeded.groupedRows == liveProjection.groupedRows` over the real recorded pipeline (row count 4 -> 5 for the narration row).

    Verification: one ungated `swift test` — 923 tests / 87 suites passed (1 pre-existing known issue in BoundedWait), plus 27 and 24 tests in the sibling targets, zero failures.
  timestamp: 2026-08-13T05:32:59.962043+00:00
- actor: claude-code
  id: 01kzwsr7fbfz73dz872mte6t6y
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Session/SessionProjection.swift, Tests/FoundationModelsRouterTests/SessionProjectionTests.swift, Tests/FoundationModelsRouterTests/SessionProjectionSeedingTests.swift; one ungated `swift test`: 923 + 27 + 24 tests passed, 0 failures
    - next: review
  timestamp: 2026-08-13T05:33:05.899473+00:00
depends_on:
- 01KZR9658E5CEVBK177RT024HY
- 01KZR96MYJ1M1XGB8855AKY6XR
position_column: doing
position_ordinal: '8180'
title: 'Grouped view: attach adjacent context to a tool call'
---
## Problem

Projection rows are flat siblings: text, reasoning, tool calls, and compaction results sit in one list, oldest first. A disclosure-style UI wants the context that led to a tool call — the reasoning entries, and the superseded pre-tool text that `SessionEvent.textReset` marks — shown inside that call's group. Today each consumer must re-derive this grouping itself, and each will do it differently.

## Proposed solution

Add one derivation rule as a computed grouped view over the flat rows. Do not restructure the stored transcript — the flat list stays the source of truth.

1. Define the rule precisely: within one turn, the `.reasoning` rows and the superseded `.text` rows (closed by `textReset`) that come immediately before a tool-call row attach to that call's group. Rows after the last tool result and the final answer text stay top-level.
2. Expose it as a computed property or function on `SessionProjection`, for example `groupedRows` returning a small row-group model: top-level rows, and per-call groups that hold the call plus its attached context.
3. Group identity must be stable: key each group on the tool call's SDK id (needs the stable-identity task).
4. The view must work the same over live rows and seeded rows.

This is a UI convenience. It must not change `apply(_:)`, the event vocabulary, or the recording.

## Acceptance

- A recorded tool-turn (reasoning, pre-tool text, one call, result, final answer) must group as: one call group holding the reasoning and the pre-tool text, then the final answer top-level.
- Two concurrent same-name calls must form two groups, keyed by their distinct call ids.
- The grouped view of a seeded projection must equal the grouped view of the live projection for the same turn. #projection