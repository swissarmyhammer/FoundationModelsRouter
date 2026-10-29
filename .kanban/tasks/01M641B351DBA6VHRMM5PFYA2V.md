---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffc680
title: 'Router: record the MTP outcome of each generation call in telemetry'
---
mlx-swift-lm (tasks 01M6419H1RXZSWFJX08Q9SGWT5 and 01M6419MQ1P0YABFMKEJHGC7R4) emits these keys on Transcript.Response.metadata when speculativeDecoding != nil:
- "speculativeDecoding" (Bool)
- "speculativeDecodingFallbackReason" (String, absent when there was no fallback)
- "acceptedDraftTokenCount" (Int)
- "draftedTokenCount" (Int)
TDD: Router reads them from the response entries of each generation call, as FinishReason reads "incompleteOutput", and records them on the generation call telemetry (span attributes + log metadata). A call with no keys records nothing. The bench run must be able to prove that MTP ran.
Then a real-model check: Qwen3.8-27B-4bit + MTP generates tokens through Router (the agent note of 2026-09-08 says it made none), and the telemetry shows speculativeDecoding=true. #mtp