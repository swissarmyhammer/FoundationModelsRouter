---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: A turn that reaches the ceiling in its answer text reports completed
---
## The problem

Card ^thrrzpc added `TokenUsage.finishReason`. It reads the `incompleteOutput` metadata that the MLX executor sends on the response entry.

The unconstrained MLX path sends that metadata ONLY when generation stops inside a reasoning block (`endedInsideReasoning` in `MLXLanguageModel.swift`). When the model closes its thought and then runs out of tokens in the answer text, no metadata arrives. `finishReason` is then `.completed`, and the turn is again silent.

## Facts to check

- `.build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift`: find each `emitMetadata(["incompleteOutput": true]` site and the condition around it.
- The ceiling of the turn is known to the session (`RoutedSessionActor.responseTokenCeiling(requested:contextTokens:)`), and `tokensOut` is known when the turn closes.

## The work

1. Decide how Router detects a truncated answer with no metadata. One candidate: `tokensOut` of the attempt is equal to or more than the ceiling the attempt gave the backend.
2. Do NOT change `Libraries/MLXFoundationModels` (upstream code).
3. Add a test with a backend that stops at the ceiling in the answer text and sends no metadata.