---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: 'GGUF: sizing a GGUF ref that names a GGUF drafter takes ~15 s longer than the plain ref'
---
## What
Measured by the gated GGUF suite (^44meq1j) on 2026-11-09, over 3 runs, each with a fresh router cache dir. Resolving the profile whose standard ref is `ggml-org/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q8_0.gguf` spends about 5 s between the `resolve` span's enter and the first `load`. With the same ref plus itself as drafter (`ModelRef(repo:path:revision:drafter:)`), the same sizing phase takes 15–20 s. That phase is `sizeCandidates`: Hub metadata plus the Range-fetched GGUFHeader, for the candidate and for its drafter. One extra GGUF header fetch should not cost 10–15 s.

## To do
Find where the time goes. Candidates: the drafter is sized serially after the candidate; the Range fetch reads more of the header than it needs; a ref and its drafter that name the same file are fetched twice instead of sharing one result. Fix it if the cause is in the router.

#gguf