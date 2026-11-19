---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7s3rdbz2hedvx6h1754kjmn
  text: |-
    ### finish iteration 1 — stuck
    - implement: stuck — not started. mlx-swift-lm origin/stable is at 94ce7e2b and has no `copyPromptCache(fromSession:toSession:)` (checked 2026-11-18). Part 1 (^2qm6eas) is done.
    - next: start again when the mlx-swift-lm session sends the sha of the copy API on stable; then update the pin with `--manifest-cache local`.
  timestamp: 2026-11-19T05:16:34.559312+00:00
depends_on:
- 01M7S15T37N1RG9ECXB2QM6EAS
position_column: todo
position_ordinal: '8180'
title: 'A fork copies the MLX prompt cache: the mlx-swift-lm pin, the conformance, and real-cache tests (D205 (f), part 2)'
---
## Goal

The MLX part of the fork cache copy. Brief: `../.briefs/fork-kv/router-brief.md` (items 1, 2, 4, 6, 7); overview `overview.md`.

## Depends on

- Part 1 (the protocol and the copy at the fork).
- mlx-swift-lm on `stable`: the public `MLXLanguageModel.copyPromptCache(fromSession:toSession:)` and `PromptCacheCopyResult`. Today `stable` is pinned at `31e5cfc9`; `94ce7e2b` moves the cache store to new files. Do not start before the mlx-swift-lm session sends the sha. Then update the pin with `--manifest-cache local` (first stop a `sourcekit-lsp` whose cwd is this repo).

## Change

- `MLXLanguageModel` conforms to the copy protocol of part 1, and maps its `PromptCacheCopyResult` to the Router result.
- A running turn of the source: take the documented result of mlx-swift-lm (a wait or `sourceInUse`). For a fork at the calling tool call, find out if the source pass checked its cache in while the tool body runs, and write the result in the doc.

## Tests (a model with a real prompt cache)

Use the scripted model of mlx-swift-lm (`MLXScriptedLM`, `TranscriptKVCache`) if the Router tests can load it, else an integration test with a small model.

- [ ] The first call of a fork reports `cachedInputTokenCount()` at least the tokens of the history up to the cut, less the tokens that the template changes at the end. For `.lastCompletedTurn`, `.callingToolCall` and `.historyPosition(n)`.
- [ ] With no copy (no cache, or `sourceInUse`), the fork prefills the whole history and answers correctly.
- [ ] Independence: a prompt to the fork does not change the cache of the source (the next turn of the source is a full hit), and the reverse.
- [ ] Greedy output: the first answer of a fork with the copy equals the first answer of a fork with no copy.
- [ ] Memory: after a fork, `promptCacheUsage` includes the copy, and the resident prompt-cache bytes stay at or below the budget that `PromptCacheBudget` sent.
- [ ] Release: a close of the fork releases the copy and keeps the cache of the source; a close of the source keeps the copy.
- [ ] A fork through the host launcher also gets the copy.

## After

Push when green. Send the sha to testudoapp-9a. #d205