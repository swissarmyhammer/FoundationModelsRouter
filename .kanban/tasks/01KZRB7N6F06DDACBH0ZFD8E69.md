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

1. Add a mid-turn observation seam to `LanguageModelSessionBackend`. Two candidate mechanisms — pick after a spike:
   - Poll the SDK session's `transcript` during generation (the SDK appends `.toolCalls`/`.toolOutput`/`.reasoning` entries as the turn runs); diff on a short interval and emit events as entries appear.
   - Or widen `ResponseFragment` into a typed mid-turn event (text delta, restart, tool call announced, tool output landed, reasoning delta) for backends that can report these directly.
2. Route the live observations through the existing `SessionEvent` vocabulary — same cases, same ids (`Transcript.ToolCall.id`), earlier delivery. The post-turn diff stays the authority for what is RECORDED; the live seam only accelerates delivery. If the diff and the live observations disagree, the diff wins.
3. Emission-order guarantee: a `.toolCall` event must arrive before its `.toolStatus(completed)`, and both before `turnEnded`. Consumers must not need changes — `SessionProjection.apply(_:)` already handles the vocabulary.

## Acceptance

- A scripted tool-using turn delivers `.toolCall` before the tool's own work completes (test with a slow scripted tool: assert the event arrives while the tool is still running).
- The recorded transcript for that turn is byte-identical to what the post-turn diff alone would have recorded.
- The stub-backend default (text-only) keeps working unchanged. #streaming