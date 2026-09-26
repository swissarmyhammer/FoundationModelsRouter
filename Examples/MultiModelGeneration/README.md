# MultiModelGeneration

Runnable demo of routing across two co-resident local models from one resolved
`Router` profile, observed end to end. The resolve reports each phase
transition through `ResolutionProgress.phases`, and the observation then
continues per answer: a quick `flash` triage message and a heavyweight `standard`
message each run through `RoutedSession.streamEvents(to:)`, printing the named
`SessionEvent` cases as they arrive: `submissionStarted` with the id and the
cause of the submission, the `textDelta` fragments, `entryRecorded`,
`submissionEnded` with measured token usage when the backend reports it, and
`answered` with the length of the reply.

## Run

```
swift run MultiModelGeneration
```

This downloads real model weights on first run and needs Apple silicon +
network access — the same constraints as the real-model test targets
(`swift test --package-path IntegrationTests`).
