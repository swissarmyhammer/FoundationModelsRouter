# MultiModelGeneration

Runnable demo of routing across two co-resident local models from one resolved
`Router` profile, observed end to end. The resolve reports each phase
transition through `ResolutionProgress.phases`, and the observation then
continues per turn: a quick `flash` triage turn and a heavyweight `standard`
turn each run through `RoutedSession.streamEvents(to:)`, printing the named
`SessionEvent` cases as they arrive — `turnStarted`, the `textDelta`
fragments, `entryRecorded`, and `turnEnded` with measured token usage.

## Run

```
swift run MultiModelGeneration
```

This downloads real model weights on first run and needs Apple silicon +
network access — the same constraints as the real-model test targets
(`swift test --package-path IntegrationTests`).
