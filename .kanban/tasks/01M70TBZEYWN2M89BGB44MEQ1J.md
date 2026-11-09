---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m711kbwtrjysp25xje8qc2fd
  text: |-
    Model choice notes from FoundationModelsLlamaCpp:
    - Use the ggml-org conversion `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf`, which keeps the MTP layers. Unsloth's regular GGUFs drop them; only its `-MTP-GGUF` repos keep them.
    - LlamaCpp's full serial real-model suite passed at c4ae2ab (77 tests). A seeded temperature-0.8 run also gives identical tokens with and without speculation.
    - A DFlash drafter with a real speedup has been tested only as Qwen3.5-4B + Anbeeld/Qwen3.5-4B-DFlash-GGUF, which LlamaCpp is adding now. It is too large for the 2-minute budget, so use MTP and the model-as-its-own-drafter case here.
  timestamp: 2026-11-09T20:57:05.690505+00:00
depends_on:
- 01M70TBC964F3BW0TM6YQ9T4ZD
- 01M70TBJ05VAPRAC8DEZ27872M
- 01M70TBSAB9VECTCB9R7K8WTQ6
position_column: todo
position_ordinal: '8480'
title: 'GGUF: real-model integration test — a GGUF profile resolves, generates, and speculates with MTP'
---
## What
A gated test in the IntegrationTests package that drives the whole router path with `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` (Extras and LlamaCpp tested with this ref, and it has nextn layers):
- `Router.resolve` of a ProfileDefinition whose standard slot is that ref. No backend is named anywhere.
- A session answers. Use greedy sampling and maximumResponseTokens around 128, and check token counts rather than the answer text: Extras saw Qwen3.5 sometimes spend its whole budget on reasoning.
- `GenerationCallUsage.speculativeDecoding?.speculated == true` with no drafter (MTP). A second case uses the model as its own drafter and checks draftedTokenCount > 0.
- A mixed profile, with an MLX candidate and the GGUF candidate, resolves by fit.
- Keep it under the 2-minute budget per integration test.

## Acceptance
- [ ] The test passes twice in a row locally. #gguf