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
- actor: wballard
  id: 01m5kw21ptkrhk7drerkh664eb
  text: |-
    ### Research — option 1 (stream arguments as the decoder parses them) is blocked

    Read the fork at `stable` 1eb84ff. No edits made in either repo.

    - No decoder in the fork parses tool-call arguments incrementally. `StandardTokenStreamDecoder` / `AllowedToolOutputRouter` (all 11 text formats: json, lfm2, xmlFunction, qwen35, glm4, gemma, gemma4, kimiK2, minimaxM2/M3, mistral, llama3, dsml) hand text to `ToolCallProcessor`, which collects the whole call (`.collectingToolCall`) until its end marker, then parses it. Harmony and Onyx (gptOSS, atem) also yield `TokenStreamEvent.toolCall(ToolCall)` complete. The only tool-call event is a finished `ToolCall`.
    - After the call is collected, `ToolCallProcessor.appendToolCall` runs `ToolArgumentNormalization.normalize` (schema-guided coercion of textual values, for example "5" -> 5), then strict `ToolSchemaValidator` validation and an undeclared-tool check, and may reject the call. Sending raw argument text as `appendArguments` fragments while the call decodes would skip that coercion: the tool would get un-normalized arguments, and a rejected call would already have fragments in the channel. That is a correctness regression, not a streaming change.
    - Without incremental parsing, the honest change is: send each tool call as soon as the decoder yields it (not at the end of generation), and stream response text as `appendText` chunks. A tool-call-only pass with one call still sends ONE output event, at the end of the call (about the end of generation). The first checkbox (more than one output event before usage) fails for that pass, and so does the Router checkbox (`first_token_seen=true`), because `PassOutputRelay` reports a first token only when a second output event follows. Splitting the finished arguments JSON into several fragments sent at the same moment would pass both tests, but the router would then record a fake time to first token. I will not do that.
    - More side effects of option 1: in allowed mode with a response schema, response text is dropped when no tool call comes and `runSchemaGeneration` runs instead, so text cannot stream there. Text before a tool call is dropped today (only the calls are sent); streaming it changes what the transcript holds.

    Option 2 on the card (a public prefill-end / first-token hook) works without these problems: `ExecutorPromptCacheSlot.prefillDidEnd` / the `.token` arm of `runAllowedToolGeneration` already know when the first token comes. A public task-local observer in MLXFoundationModels that the router binds per pass in `SessionLanguageModel` (which already imports MLXFoundationModels, so no new dependency edge) would give a true first-token time on every path. That also means Router source changes in `SessionLanguageModel` / `PassOutputRelay`, not only tests.

    Decision needed from a human: (a) switch this card to option 2, (b) take option 1 limited to "send each call when it is parsed, stream text when there is no schema", and change the checkboxes to match (tool-call-only passes stay first_token_seen=false), or (c) build incremental argument parsing plus normalization for each format (a much bigger card).
  timestamp: 2026-10-23T07:54:25.882991+00:00
- actor: wballard
  id: 01m5kw22t0e33bzx1wdex3h2m3
  text: |-
    ### implement — stuck
    - evidence: no files changed. The fork has no incremental tool-call argument decoder, and arguments are normalized and validated only after the whole call is collected (ToolCallProcessor.appendToolCall), so option 1 cannot give a tool-call-only pass more than one honestly timed output event. Details in the comment above.
    - next: a human picks option 2 (public first-token hook), a narrowed option 1 with changed checkboxes, or a separate incremental-parsing card. Fork still clean on stable 1eb84ff; no `swift package edit` was run in Router.
  timestamp: 2026-10-23T07:54:27.008300+00:00
- actor: wballard
  id: 01m5kznaterp4xyd3mn8r9h7p5
  text: |-
    ### finish — closed, won't do
    - decision (user, 2026-10-23): do not change mlx-swift-lm for this. Both checkboxes need a fork change, so the card is closed.
    - replaced by a Router-only card that labels buffered passes (generation.output_buffered).
  timestamp: 2026-10-23T08:57:23.534977+00:00
position_column: doing
position_ordinal: '80'
title: 'MLX allowed-tool path: stream response text and tool-call arguments as they decode'
---
Found in ^0m997jr. The router now takes the first token of a pass from its executor channel (PassOutputRelay), but the allowed-tool path of the MLX executor (mlx-swift-lm fork, MLXLanguageModel.runAllowedToolGeneration / runAllowedToolTurn) keeps the response text and the tool calls in AllowedToolGenerationResult until generation ends, and only then calls emit / emitToolCall. Only reasoning text streams. So a tool-call-only pass with no reasoning sends its whole output in one event at the end, and the router must mark it first_token_seen=false (45 of 105 calls in router-telemetry-16). The in-pass signals that exist (the generationObserver task-local, ExecutorPromptCacheSlot.prefillDidEnd) are internal to MLXFoundationModels.

Fix in the fork, one of:
- send tool-call arguments as appendArguments fragments while the protocol decoder parses them, and response text as appendText chunks, as runUnconstrained does; or
- expose a public prefill-end / first-token hook (for example a public task-local observer) that the router can bind per pass.

- [ ] Failing test in the fork: an allowed-mode tool-call pass sends more than one output event before its usage
- [ ] Router side: a real MLX tool-call-only call records generation.time_to_first_token_ms and generation.first_token_seen=true