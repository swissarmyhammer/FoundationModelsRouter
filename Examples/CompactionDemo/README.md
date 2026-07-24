# CompactionDemo

Runnable demo of the compaction loop end to end (compaction_plan.md §4), with
real tool traffic (task 4ce0a1k): open a `RoutedSession` vended with sample
tools (`SampleTools.swift`) and a tiny auto-compaction `TokenBudget` (task
8213x39), drive scripted turns — some plain fixture reads, some explicit tool
calls — while `contextFill` climbs, let the budget fold the transcript
automatically at the 0.80 trigger (no caller-side `session.compact()`
polling), keep talking to the same session, and restore it from disk to show
nothing was lost.

## Tools

- `generate_document` (`DocumentGeneratorTool`) manufactures configurably
  large filler text on demand — additional context pressure delivered as a
  real tool call/tool-output pair instead of a plain response.
- `record_fact` / `recall_fact` (`RecordFactTool`/`RecallFactTool`) are a
  matched pair backed by one shared `FactStore`. The demo has the model
  record a fact before the fold and recall it afterward, proving continuity
  of a different kind than plain conversational memory: the model must still
  remember *that* a fact was stored under a given key, and remain able to
  call a tool to retrieve it, after its transcript has been folded.

## Run

```
swift run CompactionDemo
```

This downloads real model weights on first run and needs Apple silicon +
network access — the same constraints as the gated integration test suite
(`FM_ROUTER_INTEGRATION_TESTS`).
