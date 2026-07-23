---
position_column: todo
position_ordinal: '9080'
title: 'Tools through the session surface: makeSession(tools:), restore, fork'
---
Harness-collapse item (harness plan §7 item 1). Thread [any FoundationModels.Tool] through RoutedLLM.makeSession to the wrapped bare LanguageModelSession (both LiveModelLoader call sites hardwire tools: [] today), through restoreSessionTree (hardcodes tools: []), and through fork(workingDirectory:). Recording schema is already tool-aware (Kind.toolCalls/toolOutput, ToolDefinitionPayload) — this gives it first real traffic. Callers pass pre-built, pre-confined tools; Router never names a tool package (constructor-fed guardrail).