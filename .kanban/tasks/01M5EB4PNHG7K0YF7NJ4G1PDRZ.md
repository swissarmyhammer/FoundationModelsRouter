---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5gkcdn2r37mcs4706cchfn5
  text: |-
    ### finish — skipped
    - skipped by /finish (2026-10-21): the fix lives in the swissarmyhammer mlx-swift-lm fork (MLXLanguageModel.runAllowedToolGeneration), another repository; it needs a fork change, a push there, and a pin bump here. Left in todo for a session working in the fork.
  timestamp: 2026-10-22T01:25:05.314813+00:00
position_column: todo
position_ordinal: '80'
title: 'MLX allowed-tool path: stream response text and tool-call arguments as they decode'
---
Found in ^0m997jr. The router now takes the first token of a pass from its executor channel (PassOutputRelay), but the allowed-tool path of the MLX executor (mlx-swift-lm fork, MLXLanguageModel.runAllowedToolGeneration / runAllowedToolTurn) keeps the response text and the tool calls in AllowedToolGenerationResult until generation ends, and only then calls emit / emitToolCall. Only reasoning text streams. So a tool-call-only pass with no reasoning sends its whole output in one event at the end, and the router must mark it first_token_seen=false (45 of 105 calls in router-telemetry-16). The in-pass signals that exist (the generationObserver task-local, ExecutorPromptCacheSlot.prefillDidEnd) are internal to MLXFoundationModels.

Fix in the fork, one of:
- send tool-call arguments as appendArguments fragments while the protocol decoder parses them, and response text as appendText chunks, as runUnconstrained does; or
- expose a public prefill-end / first-token hook (for example a public task-local observer) that the router can bind per pass.

- [ ] Failing test in the fork: an allowed-mode tool-call pass sends more than one output event before its usage
- [ ] Router side: a real MLX tool-call-only call records generation.time_to_first_token_ms and generation.first_token_seen=true