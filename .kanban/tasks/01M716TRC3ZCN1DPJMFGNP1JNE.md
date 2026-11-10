---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m72qdqyj54fq188a458e7nbj
  text: |-
    Research: `GGUFHeaderError.needsMoreBytes(atLeast:)` in FoundationModelsLlamaCpp (Runtime/GGUFHeader.swift, PrefixReader.bytes) is the end of the NEXT single read only — one string or one array element — so it carries no array size. The parse does not report the open array. Real Qwen3.5-0.8B-Q8_0 layout (fetched the first 11 MB live): tokens at 1586, 248,320 strings, 4,853,370 B (avg 19.5 B, but only 14.96 B over the first MiB — early tokens are short, so extrapolating the token average under-predicts by 23%); token_type 993,292 B; merges 247,587 strings 5,086,380 B; chat_template 7,763 B; end 10,942,704. Bytes per vocab entry: Qwen3.5 real 44.1, llama.cpp qwen35 vocab fixture 39.0, deepseek-llm 38.8, llama-bpe 61 (280k merges for 128k vocab).
    Implementation: new Router-side `GGUFMetadataScan` walks the prefix and finds the array past its end; `GGUFHeaderPrefix.read` sizes the next read as max(atLeast, scan.predictedEnd ?? 2*prefix). Token array: start + count*48 B budget (covers type + merges). Other fixed-size array: exact end + 1/4 of the remainder. Other string array: extrapolated from read strings + 1/4. Otherwise doubling as before. Qwen3.5: 5 reads / 16 MiB -> 2 reads / 11,920,946 B. llama-bpe: 4 reads -> 3 reads. No dependency change needed.
  timestamp: 2026-11-10T12:37:44.530679+00:00
- actor: claude-code
  id: 01m72qf8acqxgdvde0x7wbtwq6
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Sizing/GGUFMetadataScan.swift (new), Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift, Tests/FoundationModelsRouterTests/GGUFRepoMetadataTests.swift, Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift; `swift test` 2516+38+19 tests passed; commit 2fae5034
    - next: review
  timestamp: 2026-11-10T12:38:34.060175+00:00
- actor: claude-code
  id: 01m72qnk8q286yvjszrkvm5cyd
  text: |-
    ### review — findings
    - evidence: 1 finding — Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:180 code-hygiene/magic-numbers-swift (local swiftlint reproduced the cause at GGUFMetadataScan.swift:54, the gguf_type byte-count table; the fixture file itself lints clean). Fixed in e6dc6afe: a `ValueType` enum whose byte counts come from MemoryLayout. swift test 2516+38+19 green.
    - next: re-review HEAD~1..HEAD
  timestamp: 2026-11-10T12:42:01.879327+00:00
- actor: claude-code
  id: 01m72qz92n2p016z9y62yv5dbb
  text: |-
    ### review — findings
    - evidence: Discovery: the review MCP engine resolves `HEAD~1..HEAD` in the MAIN checkout, not this worktree — its 06:38 and 06:42 runs reviewed main's merge d9fa5fd1 (4 files incl. GGUFHeaderFixtures.swift; the :180 magic-number finding is in main's code, not this branch). Re-ran with explicit shas `6422ad77..e6dc6afe`: 2 findings, GGUFHeaderFixtures.swift:318 and :331 reuse/reuse. Both fixed in b6eb8bdf (arrayHeader(elementType:count:), append(stringBytes:to:)). The engine's swiftlint tool rules could not read GGUFMetadataScan.swift (absent in the main checkout), so I ran swiftlint no_magic_numbers/function_body_length/closure_body_length/force_* locally on the 4 files: clean. swift test 2516+38+19 green.
    - next: re-review with explicit shas
  timestamp: 2026-11-10T12:47:19.125259+00:00
- actor: claude-code
  id: 01m72r4e0kztzx8ghb07fne1hx
  text: |-
    ### review — clean
    - evidence: `review sha e6dc6afe..b6eb8bdf` 0 findings; whole-task `review sha 6422ad77..b6eb8bdf` 0 findings (2 refuted). The engine's 5 swiftlint tool rules declined GGUFMetadataScan.swift (the file is not in the main checkout where the engine runs); local swiftlint no_magic_numbers, function_body_length, closure_body_length, missing_docs, force_* over it: clean. All prior items checked. Commits 2fae5034, e6dc6afe, b6eb8bdf on worktree-agent-a8d5ffe4cb5052770.
    - next: orchestrator merges the branch
  timestamp: 2026-11-10T12:50:08.019392+00:00
position_column: done
position_ordinal: fffffffff780
title: 'GGUF: the header Range reads take 5 round trips and 16 MB for an 11 MB KV section'
---
## What
Found while working ^vf5brrc (measured 2026-11-09). `GGUFHeaderPrefix.read` (Sources/FoundationModelsRouter/Sizing/GGUFRepoMetadata.swift) starts with a 1 MiB read and, on each `GGUFHeaderError.needsMoreBytes(atLeast:)`, fetches up to `max(atLeast, 2 * prefix)`. For `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` the KV section ends at byte 10,942,704 (tokenizer.ggml.tokens 4.85 MB, merges 5.09 MB, token_type 0.99 MB), so the reader makes 5 serial Range GETs (0-1M, 1-2M, 2-4M, 4-8M, 8-16M), downloads 16 MB, and re-parses the whole prefix 5 times. Live timings: 0.71/0.29/0.34/0.45/0.86 s for the reads; one header costs 3.2-3.5 s in a debug build, and up to 9.5 s when the network is slow. After ^vf5brrc this is the whole of the GGUF sizing phase of a resolve.

## To do
Cut the round trips and the bytes: for example, grow the prefix faster, or size the next read from the length of the array that ran past the prefix (the parse knows the element count and type when it stops), so a Qwen3.5 header takes 2 reads and about 11 MB. Keep the sizing results identical, and pin the read count with a hermetic test over `FileServingMetadataSource.readRanges` and a large-array header fixture.

#gguf

## Review Findings (2026-11-10 06:38)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 0 not reviewed.

- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:180` `code-hygiene/magic-numbers-swift` — Magic numbers should be replaced by named constants.

## Review Findings (2026-11-10 06:43)

> Scope: `review sha 6422ad77..e6dc6afe` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 0 not reviewed.

- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:318` `reuse/reuse` — `signedIntegerArray(count:)` repeats the array header that `stringArray(lengths:)` already writes: the `arrayType` tag, then the element `gguf_type`, then the 64-bit count. The header is duplicated instead of being shared, so a change to the array header would have to be made in two places. Extract a helper such as `arrayHeader(elementType: UInt32, count: Int) -> Data` that writes the tag, the element type and the count. Both `stringArray` and `signedIntegerArray` would call it and then append their elements.
- [x] `Tests/FoundationModelsRouterTests/Helpers/GGUFHeaderFixtures.swift:331` `reuse/reuse` — `append(fillerLength:to:)` rebuilds the GGUF string layout (a 64-bit length, then the UTF-8 bytes) that the existing `append(text:to:)` already writes. It differs only in that the bytes are filler characters rather than a given string. The layout is duplicated instead of being extended, so a change to the string encoding would have to be made in two places. Generalize `append(text:to:)` to take the bytes (for example `append(bytes: Data, to:)`, with `append(text:)` calling it as `Data(text.utf8)`), then have `append(fillerLength:)` call it with `Data(repeating: filler, count: length)`. Alternatively, keep one helper that takes a byte count and a fill byte. Either way the length prefix is written in one place.
