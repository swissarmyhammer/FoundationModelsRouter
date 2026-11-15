---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7fgapm9nd7tb9qcw97qx94a
  text: |-
    ### Decision (user, 2026-11-15)
    "let's do a 16k window default, and let's make it settable per profile". The decision slot gets a context of its own: `ProfileDefinition.decisionContext`, defaulting to 16,384 tokens. The decision candidate is sized and loaded at that context, not at the shared window. ACPAgent has to add it to its configs.
  timestamp: 2026-11-15T11:43:52.457014+00:00
- actor: claude-code
  id: 01m7fgy1yr3knbqejk76q994es
  text: |-
    ### commit — changed
    - evidence: c08efe3d feat(resolution)!: give the decision slot a context of its own; `swift test` 2725 + 42 + 19 green (two full runs); IntegrationTests and Benchmarks build clean.
    - API: `ProfileDefinition.decisionContext: Int` (public var), init parameter `decisionContext: Int = ProfileDefinition.defaultDecisionContext` (last, after `context`), `public static let defaultDecisionContext = 16_384`; JSON without the key decodes to the default. New `SlotProgress.contextTokens: Int?`; span attributes `context.tokens` and `context.decision_tokens`; `ResolvedProfile.decisionContext` (required).
    - note: an allocated MLX key serves any decision context (Router SlotPricing.isAllocated uses `withoutContext` when the candidate is not GGUF); a GGUF key serves up to its own context.
  timestamp: 2026-11-15T11:54:26.648291+00:00
position_column: done
position_ordinal: ffffffffff9980
title: Size and load the decision model at a context of its own, not the shared window
---
## Problem
Since ^ybx7vvn the decision slot is a required slot that is fitted in the same attempt as the trio, at the shared context. With a derived window (ACPAgent flint24: 219,442 tokens), a GGUF decider such as h2o-lightning-4b is sized at that window, and llama.cpp allocates its whole KV at load. For a Qwen3-4B-shaped model (36 layers, 8 KV heads, head dim 128), fp16 KV is about 147 KB per token, so about 32 GB at 219K tokens. That squeezes the standard window, although a decision state is usually small.

## Question for the user
What context should the decision slot get? Options:
- a fixed constant (for example 8K or 32K);
- a `ProfileDefinition.decisionContext`;
- the shared window (today).

The host builds the `DecisionState`, so its size is the host's to bound.

## Done when
The decision slot's pool key and footprint use the chosen context, and the window search charges the decision KV at that context. Hermetic tests cover a derived window with a GGUF decider. #bug