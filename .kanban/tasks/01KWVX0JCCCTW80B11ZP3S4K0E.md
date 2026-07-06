---
assignees:
- claude-code
depends_on:
- 01KWVX03H6XEBFVZR3M070QW7Z
position_column: todo
position_ordinal: '8580'
title: Update plan.md to reflect session-as-factory architecture
---
## What

`plan.md` currently describes the router as a stateless invoker (`MLXFoundationModelsContainer` creates a fresh `LanguageModelSession` per call) and documents the `fork()` KV-cache limitation as the reason prefix-reuse is unavailable. Both are now wrong. Update the document to reflect the corrected architecture.

**Sections to revise in `plan.md`:**

- **Backends:** Replace the "fresh session per call" description. Document that `MLXFoundationModelsContainer` is a factory (`makeSession(instructions:) -> LanguageModelSessionBackend`), `MLXFoundationModelsSessionBackend` holds a `LanguageModelSession` for its lifetime, and all generation calls go through that persistent session. Remove any claim that "a fresh `LanguageModelSession` is constructed per call."
- **Sessions & KV cache:** Update the `fork()` section. `fork()` now seeds the child session using `LanguageModelSession.init(model:tools:transcript:)` from the parent's transcript — conversation history is properly inherited. Retain the honest note that the `MLXLanguageModel.Executor` re-derives `LMInput` from the full transcript on each turn (no GPU-level KV cache reuse across turns), but clarify this is a performance observation, not a correctness gap.
- **`LanguageModelSessionBackend` protocol:** Add a short description of the new seam — factory produces backends, backends own the session and transcript, `makeFork` seeds from transcript.
- **Decisions:** Add an entry recording why the stateless invoker was replaced: it silently discarded all conversation history, making every turn effectively single-turn.

## Acceptance Criteria
- [ ] `plan.md` no longer says "fresh `LanguageModelSession` per call" anywhere
- [ ] `plan.md` correctly describes `LoadedLLMContainer` as a session factory
- [ ] `plan.md` documents `makeFork` using `LanguageModelSession.init(model:tools:transcript:)` for transcript continuation
- [ ] The KV performance caveat (re-derives from full transcript each turn) is retained but correctly scoped as performance, not correctness

## Tests
- [ ] No automated tests — documentation only
- [ ] Reviewer confirms accuracy against the implemented code

## Workflow
- Read the current Backends and Sessions sections, then rewrite in place with `edit file`.