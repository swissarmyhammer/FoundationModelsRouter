---
assignees:
- claude-code
depends_on:
- 01M641AJ90YY9WZ3XAZ5D0SMDR
position_column: done
position_ordinal: ffffffffc580
title: 'Router: load the MTP drafter of a profile ref and charge its bytes in JointFit'
---
Depends on the Extras card (ModelRef.drafter, MLXModelLoader drafterRegistration). TDD:
1. LiveModelLoader builds its Extras MLXModelLoader with `drafterRegistration: .matchingTarget(.qwen35Text, .qwen35VLM)`, because Router links MLXVLM and `loadModelContainer` loads a Qwen3.5-family target as a VLM.
2. JointFit: a candidate whose ref has a drafter is charged target footprint + drafter weight bytes. Router.sizeCandidates fetches the drafter metadata too. A drafter whose metadata is unavailable makes the candidate metadataUnavailable.
3. The profile YAML accepts `- {repo: mlx-community/Qwen3.8-27B-4bit, drafter: mlx-community/Qwen3.8-27B-MTP-4bit}` in a slot list.
Bump the mlx-swift-lm and Extras pins in Package.resolved and IntegrationTests/Package.resolved. #mtp