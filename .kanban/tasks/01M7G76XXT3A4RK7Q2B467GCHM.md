---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffff9b80
title: Take Muse Glimmer out of the integration tests
---
User decision (2026-11-15): "let's take muse glimmer out of the integration tests". Part of getting the integration job well under 30 minutes (mini-01, 32 GB, decodes a 27B at 6.4 tok/s against 30.6 on m3u1).

- `RealModels.standard` (Muse-Glimmer-30B-mxfp4, 17 GB) becomes `mlx-community/Qwen3-4B-4bit`; `RealModels.flash` becomes `mlx-community/Qwen3-1.7B-4bit`. Both dense Qwen3, so every cache entry is trimmable and the prompt-cache reuse claims hold.
- The pinned chat-template date suite moves from Glimmer (`current_date`) to Llama-3.2-1B (`date_string`). The hermetic `PinnedDateTokenizerLoaderTests` keep the Glimmer key.
- Docs that name Glimmer as the gated model follow.

Suites on `RealModels.standard`: LanguageModelSessionBackendTests (414 s on mini-01), SessionTreeRestoration (tool-calling), TranscriptReconstruction, CompactionSpike, GGUFProfile (largeMLXModel), GatedRealProfile, PinnedChatTemplateDate.

Test: the integration package builds; the changed suites pass locally on real models (GPU free); CI time on mini-01. #test