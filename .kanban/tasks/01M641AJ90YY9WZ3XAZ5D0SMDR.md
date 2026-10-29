---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffc480
title: 'Extras: ModelRef names an MTP drafter; MLXModelLoader speculates with it and counts its bytes'
---
Asked by the ACP agent session (2026-10-29): Router must turn on MTP for the SWE-bench standard slot (mlx-community/Qwen3.8-27B-4bit + head mlx-community/Qwen3.8-27B-MTP-4bit). The MLXLanguageModel is built in Extras `MLXModelLoader.loadLanguageModel` and never passes `speculativeDecoding:`, so every call runs plain decode. This change is in FoundationModelsExtras (../FoundationModelsExtras).

TDD, with a failing test first for each part:
1. `ModelRef.drafter: ModelRef?`. It decodes from the plain string (no drafter) or from the mapping `{repo: "org/target[@rev]", drafter: "org/drafter[@rev]"}`. It encodes back to the string when there is no drafter, else to the mapping. `stringValue` stays the target. Hashable includes the drafter.
2. `MLXModelLoader(..., drafterRegistration: MTPDrafterRegistration)`. Default `.qwen35Text`. A host that links MLXVLM passes `.matchingTarget(.qwen35Text, .qwen35VLM)`. An `.llm` key whose ref has a drafter gets `MLXSpeculativeDecoding(drafterConfiguration:from:using:registration:)`.
3. `footprintBytes(of:)` adds the drafter weight bytes to the target bytes.
Bump mlx-swift-lm stable to 148f227 (the MTP API). #mtp