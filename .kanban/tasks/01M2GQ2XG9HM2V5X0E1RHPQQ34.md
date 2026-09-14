---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A tool-calling turn that reaches the ceiling in its answer text reports completed
---
## The problem

Card ^52rb0ef added a count rule to `FinishReason`: an attempt with one generation call ends at `.maxTokens` when its output token count is equal to or more than the ceiling it gave the backend.

An attempt that called a tool makes more than one executor call inside one `LanguageModelSession.respond`. `liveSession.usage` gives only the sum of all calls. The sum does not tell which call stopped. Thus the count rule does not apply to such an attempt (see `FinishReason.generationCalledTool`), and a tool turn that runs out of tokens in its final answer text still reports `.completed`.

## Facts to check

- `Transcript.Response` has no usage of its own in the SDK swiftinterface.
- `LanguageModelSession.ResponseStream.Snapshot` has `usage` and `transcriptEntries`. The stream path can maybe see the usage when each `.toolCalls` entry appears.
- The unconstrained MLX path (`MLXLanguageModel.swift`) sends `.updateUsage` on the response entry id of each call.

## The work

1. Find a way to know the output token count of the last generation call of an attempt, or ask upstream to mark a stop at the ceiling in the answer text with `incompleteOutput`.
2. Do NOT change `Libraries/MLXFoundationModels` (upstream code) from this repository.
3. Add a test with a tool loop whose last call stops at the ceiling in the answer text.