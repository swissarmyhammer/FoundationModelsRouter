---
assignees:
- claude-code
depends_on:
- 01KZR9658E5CEVBK177RT024HY
position_column: todo
position_ordinal: '9080'
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