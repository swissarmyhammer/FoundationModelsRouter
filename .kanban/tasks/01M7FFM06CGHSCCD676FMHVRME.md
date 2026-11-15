---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
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