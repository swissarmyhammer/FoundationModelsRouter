---
assignees:
- claude-code
depends_on:
- 01KZPW9RY91W2KAMGY3W8DZVEE
position_column: todo
position_ordinal: '9980'
title: Stream tool and reasoning events live during the turn, not after it
---
## Problem

A turn's tool and reasoning events are not live. The backend seam streams text only: `ResponseFragment` is the whole mid-turn vocabulary (Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift:102). `SessionEvent.toolCall`, `.toolStatus`, and `.reasoningDelta` are synthesized after generation finishes, when the turn's snapshot diff runs — `SessionProjection`'s own doc states this (Sources/FoundationModelsRouter/Session/SessionProjection.swift:42-48). A UI therefore shows "running tool" only after the whole turn is over. On a local model, a tool turn can take many seconds; the user watches a spinner with no truth in it.

This is about WHEN events arrive. Task ^w8dzvee is about WHAT the stream says (the textReset invariant); the two are separate.

## Proposed solution

The tool half needs no polling: the per-call `ToolContext` binding layers already observe the true invocation moment. `DetachingTool` (String-output tools) and `ContextBindingTool` (the rest) bind a stamped context — tool name, op, sessionID, per-call correlationID — around each call and hold the session's event sink (Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:361-372, :811-822).

1. Emit a typed invocation record from the binding layer: opened-at when the binding opens, closed-at and duration when the wrapped call returns, carrying tool, op, correlationID, and sessionID. Post it through the sink the binding already holds — the same route operation events take.
2. The session actor translates those records into live `SessionEvent.toolCall` / `.toolStatus` deliveries on the current turn's stream, using the same ids the post-turn diff will confirm. The diff stays the authority for what is RECORDED; the live records only accelerate delivery. If the diff and the live records disagree, the diff wins.
3. Reasoning and text-restart liveness stays on the fragment stream (`ResponseFragment`); widen it only if the backend can report reasoning deltas directly.
4. Emission-order guarantee: a `.toolCall` event arrives before its `.toolStatus(completed)`, and both before `turnEnded`. Consumers need no changes — `SessionProjection.apply(_:)` already handles the vocabulary.
5. Surface the invocation records (with timing) to `TurnOutcome` (task ^1s8p8qt), so a caller gets per-call durations without touching the event stream.

## Acceptance

- A scripted tool-using turn delivers `.toolCall` before the tool's own work completes (test with a slow scripted tool: assert the event arrives while the tool is still running).
- The recorded transcript for that turn is byte-identical to what the post-turn diff alone would have recorded.
- Each invocation record carries opened-at, closed-at, and duration, and reaches `TurnOutcome`.
- The stub-backend default (text-only) keeps working unchanged. #streaming