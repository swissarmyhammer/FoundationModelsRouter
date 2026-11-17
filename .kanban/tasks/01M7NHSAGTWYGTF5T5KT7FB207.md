---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffffaa80
title: Resolve and load spans name the drafter and the KV cache bits
---
ACPAgent asked for this: from the telemetry of its q8kv8 run it cannot confirm that MTP-8bit and kvBits 8 were applied.

- The resolve span gets `model.drafter.<slot>`, the canonical drafter ref, written only for a slot whose chosen model has one, and `kv_cache.bits` (Int64): 8 or 4, or 16 for fp16.
- Each load span of a language model gets `model.drafter` (when there is one) and `kv_cache.bits`. An embedding load span carries neither.
- Tests extend ResolveTracingTests, with a profile that has a drafter and kvCacheQuantization .bits8. Then push and send the SHA to foundationmodelsacpagent-62.