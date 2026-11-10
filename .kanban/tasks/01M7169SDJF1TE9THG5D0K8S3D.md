---
assignees:
- claude-code
position_column: doing
position_ordinal: '8280'
title: 'GGUF: warn before download when a DFlash drafter has no dflash.target_layers'
---
## What
GGUF sizing (^7k8wtq6) already warns when a GGUF drafter has architecture `dflash-draft`, which mainline llama.cpp won't load. It could not catch the second unloadable case, an old converter that writes architecture `dflash` with no `dflash.target_layers` key, because GGUFHeader didn't expose that key.

FoundationModelsLlamaCpp 0541b99 (pushed) adds `public let dflashTargetLayers: [Int]?` to GGUFHeader. It is nil when the key is absent and is parsed from the same prefix.

Warn (same logger and message shape as the dflash-draft warning) when either holds:
- architecture == "dflash-draft"
- architecture == "dflash" && dflashTargetLayers == nil

Real headers: Anbeeld/Qwen3.5-4B-DFlash-GGUF has 8 target layers and loads. lym00/Qwen3-4B-DFlash-GGUF-Test has none, so it falls back with drafterNotLoaded.

Update the `## Decisions` text on ^7k8wtq6, or note it here, so the skipped check is now covered. Bump the FoundationModelsLlamaCpp resolution to 0541b99 or later.

## Acceptance
- [ ] A hermetic test: a `dflash` drafter header without target layers logs the warning, a header with them does not, and `dflash-draft` still warns. #gguf