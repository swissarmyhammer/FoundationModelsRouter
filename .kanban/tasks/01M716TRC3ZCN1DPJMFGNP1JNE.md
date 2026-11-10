---
assignees:
- claude-code
position_column: doing
position_ordinal: '8180'
title: 'GGUF: the header Range reads take 5 round trips and 16 MB for an 11 MB KV section'
---
## What
Found while working ^vf5brrc (measured 2026-11-09). `GGUFHeaderPrefix.read` (Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift) starts with a 1 MiB read and, on each `GGUFHeaderError.needsMoreBytes(atLeast:)`, fetches up to `max(atLeast, 2 * prefix)`. For `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` the KV section ends at byte 10,942,704 (tokenizer.ggml.tokens 4.85 MB, merges 5.09 MB, token_type 0.99 MB), so the reader makes 5 serial Range GETs (0-1M, 1-2M, 2-4M, 4-8M, 8-16M), downloads 16 MB, and re-parses the whole prefix 5 times. Live timings: 0.71/0.29/0.34/0.45/0.86 s for the reads; one header costs 3.2-3.5 s in a debug build, and up to 9.5 s when the network is slow. After ^vf5brrc this is the whole of the GGUF sizing phase of a resolve.

## To do
Cut the round trips and the bytes: for example, grow the prefix faster, or size the next read from the length of the array that ran past the prefix (the parse knows the element count and type when it stops), so a Qwen3.5 header takes 2 reads and about 11 MB. Keep the sizing results identical, and pin the read count with a hermetic test over `FileServingMetadataSource.readRanges` and a large-array header fixture.

#gguf