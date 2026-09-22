---
assignees:
- claude-code
depends_on:
- 01M34GC0FRM3175J7XJJ6B24GD
- 01M34GCP8GJ5ACP29ZH9DDJKJM
- 01M34H27HEABW92JPTM5E8G7PZ
position_column: todo
position_ordinal: '8380'
title: Compact and continue when an append stops at the token ceiling
---
## Problem

When the last generation call of a turn stops at its output token ceiling, the turn ends as truncated and the work is lost. Evidence: django__django-13964, 2026-09-21: 33 minutes, 41 rounds, no patch.

The ceiling of that call was the context window itself (262,144), not the 8,192 floor. The ACP agent gives `maxTokens: nil`, and `responseTokenCeiling(requested:contextTokens:)` gives `contextTokens` for that case. The peer session measured `context=262144` at session start. No ceiling hunt is needed.

## Do this

A ceiling stop returns from the generate call. It does not throw. Thus the session keeps its entries, and this case is simpler than ^9ddjkjm.

1. After an attempt returns, when its finish reason is the ceiling (`FinishReason` maxTokens, see `Session/FinishReason.swift`) and the measured context is at or over `triggerTokens`: compact with `performAutoCompaction`, emit `.compaction`, then run one continuation attempt in the same turn.
2. Use the same short continuation prompt as ^9ddjkjm ("the context was compacted, your last output was cut, continue the task").
3. Limit the continuations in one turn.
4. When the context is under the trigger, do not compact. A cut output with room left is a different problem, and a compaction does not help it.

## Acceptance

- A test with a scripted backend that stops one attempt at the ceiling while over the trigger: one compaction runs, one continuation attempt runs, the turn ends with a response and the caller sees one turn.
- The same script under the trigger: no compaction, the turn ends as truncated as today.

Requested by foundationmodelsacpagent-08. #compaction