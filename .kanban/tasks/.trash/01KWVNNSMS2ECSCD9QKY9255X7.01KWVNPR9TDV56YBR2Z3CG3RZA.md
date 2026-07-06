---
position_column: todo
position_ordinal: '80'
title: Fix MLXLanguageModel's tool-calling to delegate to FoundationModels' own multi-turn session machinery instead of a hand-rolled single-turn envelope
---
## What
`Libraries/MLXFoundationModels/MLXLanguageModel.swift`'s `Executor.respond(to:model:streamingInto:)` implements tool-calling itself: it builds a synthetic "finalAnswer" tool, constrains output via a structural-tag xgrammar grammar derived from the declared tools, and parses the result into either a tool-call or a final-answer event. This works for exactly one round: the code has an explicit, documented cap —

```
// Single-turn tool-calling cap: if the transcript already contains prior tool-call or
// tool-output entries, this is a continuation round from LanguageModelSession's
// auto-loop (it executed the tool and re-invoked us with the result appended). Our
// TranscriptConverter drops those entries, so re-entering the tool-calling branch
// would just make the model emit the same tool call again -- an infinite loop. Fall
// through to text generation so the session terminates cleanly after one round.
//
// Multi-turn tool calling -- where the model sees tool outputs in the transcript
// and continues with a data-aware response -- is not supported.
```

This means a consumer who registers two or more tools with a real `LanguageModelSession(model: MLXLanguageModel(...), tools: [...])` can only ever get ONE native tool call per session turn — a continuation round after a tool result comes back silently falls through to plain, unconstrained text generation instead of allowing a second tool call. This defeats the entire point of Apple's `LanguageModelSession`'s built-in multi-turn tool-orchestration loop (which the framework itself supports for its own `SystemLanguageModel` — this adapter's `Executor` conformance is what's failing to participate in that properly), and blocks any consumer (e.g. the sibling `FoundationModelsMultitool` package) that needs a model to call one tool (e.g. a discovery/search tool), read the result, then call a second tool (e.g. an execution tool) in the same session.

Root cause: this `Executor` reimplements the tool-calling decision loop from scratch (its own synthetic finalAnswer envelope + structural-tag grammar + single-shot dispatch) rather than delegating repeated tool-call/tool-result rounds to FoundationModels' own session/transcript continuation machinery the way `LanguageModelExecutor` conformances are expected to. Fix this so a `LanguageModelSession` backed by `MLXLanguageModel` supports genuine multi-turn tool-calling: the model calls a tool, sees the tool's result appended to the transcript on the next round, and can decide to call another tool (or the same one again, or answer) — not just fall through to unconstrained text after the first call.

## Acceptance Criteria
- [ ] A `LanguageModelSession(model: MLXLanguageModel(...), tools: [toolA, toolB])` can call `toolA`, receive its result in the transcript, and subsequently call `toolB` (or call `toolA` again) within the same session — not just fall through to plain text generation after the first tool call.
- [ ] The existing single-round tool-calling behavior (call one tool, get a final answer) remains correct — no regression for the common one-tool-call case.
- [ ] The `isContinuationAfterToolCall` short-circuit (or its replacement) no longer unconditionally routes every continuation round to the unconstrained text path — it should still route to tool-aware constrained generation when tools remain relevant to complete the request, and only fall through to plain text once the model is actually done calling tools.

## Tests
- [ ] A new or updated test in `Tests/MLXFoundationModelsTests/` (or wherever this adapter's existing tool-calling tests live) that registers two distinct tools with a `LanguageModelSession`, scripts/stubs the model to call the first tool, then asserts the session's second round is still capable of invoking the second tool (not silently downgraded to unconstrained text) — the regression test for this exact bug.
- [ ] Existing single-round tool-calling tests continue to pass (no regression).
- [ ] Full test suite for this target passes.

## Workflow
- Use `/tdd` — write the multi-turn tool-calling test first (watch it fail against the current single-turn cap), then fix `Executor.respond(to:model:streamingInto:)`'s continuation-round handling to make it pass.
