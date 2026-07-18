---
assignees:
- claude-code
depends_on:
- 01KXTFR8MQDD7MF8J1NVCHKNHC
- 01KXTFSH9RM2WAYMXD9VVJFKFB
position_column: todo
position_ordinal: '8580'
title: Summarization stage + CompactionPrompt.default
---
## What
Add the model-assisted final stage (compaction_plan.md §1.3 stage 3, §2) in `Sources/FoundationModelsRouter/Compaction/`:

- `CompactionPrompt.swift` — `public struct CompactionPrompt: Sendable { var name: String; var text: String; static let `default`: CompactionPrompt }`. The default's text is the researched prompt in compaction_plan.md §2, verbatim (7 numbered sections: Intent / Constraints & decisions / Completed / In progress / Files & code / Errors & fixes / Next steps; security-relevant instructions preserved VERBATIM; no padding). Default name e.g. "router-default-v1" so evals can attribute quality by name. (This task owns the `CompactionPrompt` type — the model-free pipeline task deliberately has no prompt parameter.)
- `Summarization.swift` — renders the folded span to text, summarizes it with the compaction prompt via an injected summarizer model (default: the session's own model; profile `flash` slot as documented override), synthesizes the summary entry carrying the text segment + `CompactionSegment` (live-window entry ids, folded ids, tokens before/after, stages, prompt name). Long spans summarize in chunks then summarize the summaries (map-reduce) so the summarizer never overflows its own context.
- Extend `Compactor.compact` to `compact(_ transcript: Transcript, prompt: CompactionPrompt = .default, budget: TokenBudget)` (adding the prompt parameter the model-free skeleton omitted) and wire the stage in as the last stage; `CompactionResult.summary` carries the summary text.

## Acceptance Criteria
- [ ] Summary entry carries text segment + fully-populated `CompactionSegment`
- [ ] Map-reduce: a folded span exceeding the summarizer's budget is chunked, chunk summaries are re-summarized, and the final summary is a single entry
- [ ] Custom `CompactionPrompt` is used verbatim and its `name` lands in the segment; `.default` matches §2 text
- [ ] No summarizer available → pipeline degrades to the deterministic stages (model-free fallback)

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` — scripted/fake summarizer model returns canned summaries; asserts chunking boundaries, prompt assembly (default and custom), segment contents, fallback path
- [ ] `swift test --filter SummarizationStage` passes

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction