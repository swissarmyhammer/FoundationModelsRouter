---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Compaction writes an empty summary against an always-reasoning model — the summarizer budget has no room for the think block
---
Found by the gated real-model run of `FM_ROUTER_INTEGRATION_TESTS=1 swift test` against `aff8b1b`, recorded on `^z6xdyqn`.

## What happens

Compaction folds correctly and then stores an empty summary. The gated evals show it on every seed:

```
- seed=<name> class=summaryLostFact factInSummary=false folded=true summarizerCalls=1 stages=ToolOutputElision,TurnTruncation,Summarization
  summary=
```

- 19 seeds. `folded=true` on all 19. `summarizerCalls=1` on all 19.
- `factInSummary=false` on 19 of 19.
- `summary=` is empty on 19 of 19.

The fold works. The summarizer runs. The summary holds no text.

## Why

The gated model always reasons. It writes a `<think>` block first and the answer after it. `Tests/FoundationModelsRouterTestSupport/GatedRealModelBudget.swift` measured this and records it:

> A ceiling with space for the answer alone is not sufficient. The `<think>` block uses all of it, generation stops in the middle of the reasoning, and the turn records an empty response.
> `PropagationProbeIntegrationTests` fails with `512`: its `responseContent` is empty. The same test passes with `4096`.

`Summarization` does not use that ceiling. It computes its own in `Sources/FoundationModelsRouter/Compaction/Summarization.swift`:

- `outputTokenCeiling(ingesting:)` = `max(minimumSummaryTokens, ceil(tokens * summaryTokenRatio))`
- `minimumSummaryTokens` = `128`
- `summaryTokenRatio` default `0.25`, `maxChunkTokens` default `2000`
- `maximumOutputTokens` = `outputTokenCeiling(ingesting: maxChunkTokens)` = **500**

So each summarizer call gets 500 output tokens at most, and 128 at least. The repository already measured 512 as too small for this model. The largest budget the summarizer can ask for is below the value that is known to fail.

The stub suite cannot see this. A stub summarizer returns text whatever the ceiling is.

## Scope

The budget arithmetic keeps a summary short on purpose. Do not simply delete the ceiling. The summary must stay bounded, and the model must still get room to reason. The fix must separate the two amounts: the tokens the answer may occupy, and the tokens the model spends before the answer starts.

## Acceptance Criteria

- [ ] The summarizer gives a reasoning model room for its `<think>` block and still bounds the summary text
- [ ] `Summarization` does not silently accept an empty summary — an empty summarizer answer is reported, not stored as a fold result
- [ ] A unit test covers an empty summarizer answer, so the stub tier can see this class of fault
- [ ] `CompactionRoundTripIntegrationTests` recall of `CRIMSON-77` passes against the real model
- [ ] The gated evals report `factInSummary=true` on the large majority of seeds, and `factRetention >= 0.9` passes #defect #real-model #compaction