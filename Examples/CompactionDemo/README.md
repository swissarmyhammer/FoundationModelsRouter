# CompactionDemo

Runnable demo of the compaction loop end to end (compaction_plan.md §4): open
a `RoutedSession`, drive scripted turns that read fixture documents into the
conversation while `contextFill` climbs, fold the transcript with
`session.compact()` at the 0.80 trigger, keep talking to the same session, and
restore it from disk to show nothing was lost.

## Run

```
swift run CompactionDemo
```

This downloads real model weights on first run and needs Apple silicon +
network access — the same constraints as the gated integration test suite
(`FM_ROUTER_INTEGRATION_TESTS`).
