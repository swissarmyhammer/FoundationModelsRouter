---
assignees:
- claude-code
depends_on:
- 01M70TB3W99163V7F38SFR7SPN
position_column: todo
position_ordinal: '8380'
title: 'GGUF: size a GGUF candidate (and its drafter) before download'
---
## Problem
Resolution sizes each candidate before download (`RepoMetadata`, `HuggingFaceMetadataSource.fetchRawMetadata(repo:revision:)`, `LocalRepoMetadata`, `Footprint`, JointFit). It reads `config.json` (layers, heads, head dim, native context) and the `*.safetensors` sizes from the tree. A GGUF repo has neither: the hyperparameters live in the GGUF header. Sizing also ignores `ModelRef.path` today, and a local reference may now be a single `.gguf` file.

## What
- Pick the files with Extras' `GGUFFileSet.select(from:under:)` over the tree listing scoped to `ref.path` (or over the local folder or file).
- Weight bytes: the sum of the shard sizes in the tree, plus the projector.
- KV and native context: read the GGUF header of the first shard. On the Hub, fetch only the header bytes with an HTTP Range request; don't download the model. Parse block_count, head_count_kv, key/value length, the full-attention layers of hybrid models, and `<arch>.context_length`. FoundationModelsLlamaCpp's `GGUFMetadataReader` already parses these (`hyperparameters(of:)`, `trainingContextSize(of:)`), but it is internal and reads only from a file URL. Ask the LlamaCpp session (foundationmodelsllamacpp-f1) for a public parse that works on header bytes, rather than writing a second GGUF parser here.
- Drafter: size a GGUF drafter the same way. `Router.drafterWeightBytes` already adds a drafter's weights.
- The metadata cache key has to include the path, so two quants in one repo don't collide.

## Acceptance
- [ ] Hermetic tests from a recorded tree listing and header bytes: a single file, a split set, a projector, and a hybrid model.
- [ ] A local `.gguf` file and a local folder are both sized.
- [ ] JointFit picks between an MLX candidate and a GGUF candidate on fit alone. #gguf