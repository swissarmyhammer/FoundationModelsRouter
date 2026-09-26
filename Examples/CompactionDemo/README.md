# CompactionDemo

Runnable demo of one automatic compaction, narrated. It shows compaction and
only compaction, in three steps a person reads off the terminal:

1. Scripted messages read the project documents under `Fixtures/` into a
   `RoutedSession` whose `TokenBudget` puts the compaction trigger at a
   synthetic, low fraction of the working context. After each answer the demo
   prints measured usage against the trigger, and once usage crosses it, the
   demo says why the next answer will compact.
2. That next answer compacts the transcript before it generates — no caller ever
   invokes `session.compact()` — and the compaction's checkpoint event
   (`SessionEvent.compaction`) prints the moment it arrives.
3. The compacted summary the compaction wrote — the text the model now reads in
   place of the compacted answers — prints last.

The session model is small (`mlx-community/Llama-3.2-1B-Instruct-4bit`, the
same one the compaction smoke tests drive), the summary is written by the
profile's `flash` slot (`mlx-community/GLM-4-9B-0414-4bit` — auto-compaction
prefers `flash` as its summarizer tier), and decoding is pinned to `.greedy`,
so the run finishes in well under two minutes and repeats exactly.

## Run

```
swift run CompactionDemo
```

The first run downloads real model weights and needs Apple silicon plus
network access — the same constraints as the integration test packages.
