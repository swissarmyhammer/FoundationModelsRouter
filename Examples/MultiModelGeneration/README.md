# MultiModelGeneration

Runnable demo of routing across two co-resident local models from one resolved
`Router` profile: a quick `flash` triage turn, then a heavyweight `standard`
turn streamed fragment by fragment.

## Run

```
swift run MultiModelGeneration
```

This downloads real model weights on first run and needs Apple silicon +
network access — the same constraints as the gated integration test suite
(`FM_ROUTER_INTEGRATION_TESTS`).
