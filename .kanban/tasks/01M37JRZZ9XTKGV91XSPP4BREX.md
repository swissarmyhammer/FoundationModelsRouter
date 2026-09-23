---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Decide the 4096 defaultMaxTokens of the mlx-swift-lm executor
---
## Finding (from ^wn4zecb)

The fork `swissarmyhammer/mlx-swift-lm`, file `Libraries/MLXFoundationModels/MLXLanguageModel.swift:843`, has `private static let defaultMaxTokens = 4096`. The executor uses it when `GenerationOptions.maximumResponseTokens` is `nil` (lines 1777, 2126, 2311, 2404, 2512).

After ^wn4zecb, the router backend sends `nil` when the caller names no ceiling and the session gives no context. A routed session always gives its context (the window), so this path is only a direct backend call.

## Question for the owner

This is an invented limit in the dependency. Keep it, remove it in the fork (decode to the window of the model), or make the backend always send a number. The owner decides. #limits