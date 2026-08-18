---
assignees:
- claude-code
position_column: todo
position_ordinal: '9080'
title: The 20-minute limit on the continuity eval tier is an analogy, not a measurement
---
Filed from the backlog audit at `dd55fcd2c`, as the narrow residue of `^y0mhcdq`. That card said both gated evals go over one shared limit of 20 minutes. That is no longer true, and the card is closed. This card holds the one part that is still true.

## The residue

`gatedEvalSuiteTimeLimitMinutes = 20` now applies to the continuity suite alone (`Tests/FoundationModelsRouterEvals/CompactionContinuityEvaluationTests.swift:246`).

The two compaction fact-retention tiers each measured a limit of their own:

- `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:1424` — the subset tier, 30 minutes
- `Tests/FoundationModelsRouterEvals/CompactionEvaluationTests.swift:1454` — the whole-dataset tier, 120 minutes

`Tests/FoundationModelsRouterEvals/Support/GatedEvalSerialGate.swift:78-92` states the rule: the shared ceiling applies "when the suite has measured no ceiling of its own".

The continuity tier measured none. `GatedEvalSerialGate.swift:81` still gives its source as an analogy: "Matches `CompactionRoundTripIntegrationTests`". No gated run of the continuity suite has ever been timed end to end at the current dataset size and the current model.

## Work

Time the continuity suite end to end in a gated run. Write the measured duration on this card. Then set the continuity tier its own measured constant, the same as the two fact-retention tiers have, and state the measurement in the doc comment.

Keep the stated purpose of the limit: to bound a hung real-model load. The new value must still serve it.

## Acceptance Criteria

- [ ] A gated end-to-end run of the continuity suite is timed, and the duration is written on this card
- [ ] The continuity tier has its own time-limit constant, set from that measurement with headroom
- [ ] The doc comment of the new constant states the measurement, not an analogy
- [ ] `GatedEvalSerialGate.swift:81` no longer names `CompactionRoundTripIntegrationTests` as the source of a value the continuity suite uses
- [ ] `FM_ROUTER_INTEGRATION_TESTS=1 swift test` reports no time-limit issue from the continuity suite #eval #test-debt