---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: 'The KV cache reuse integration test is red: turn 2 reports a cachedTokenCount of zero'
---
The non-gated integration run is red on a test that has nothing to do with compaction. Measured on 2026-08-20 with `swift test --package-path IntegrationTests`, skipping the three compaction eval tiers:

```
✘ Test "turn 2's usage.input.cachedTokenCount is positive and approximates
   everything turn 1 processed — the KV cache is reused, not recomputed"
   LanguageModelSessionBackendTests.swift:569  Expectation failed: turn2Usage.input.cachedTokenCount > 0
   LanguageModelSessionBackendTests.swift:580  Expectation failed: abs(turn2Usage.input.cachedTokenCount - turn1ProcessedTokenCount) <= tolerance
✘ Suite "Gated real-model coverage: MLXFoundationModelsSessionBackend (milestone 7)"
   failed after 307.5 s with 2 issues
Test run with 29 tests in 14 suites failed after 1361.8 s with 2 issues
```

Task ^m03heaa found this while it ran the non-gated integration suite for its own work. The failing test is in `MLXFoundationModelsSessionBackend`, and ^m03heaa changed no file that reaches it, so the failure is not that card's.

The first assertion is the informative one: `turn2Usage.input.cachedTokenCount` is zero, so the second turn reports that it reused NO tokens of the first turn's prompt. Either the backend no longer reuses the KV cache across turns of one session, or the usage stamp no longer carries the count. The two have very different costs, so find out which one it is before you change anything.

## What to build

- Find whether the cache is really not reused, or only not reported. Read what the second turn costs in wall clock beside what the first turn costs: a turn that truly recomputes the whole prompt is much dearer than one that reuses it.
- If the reuse is gone, correct the backend.
- If only the stamp is gone, correct the stamp.
- Do not lower the tolerance and do not weaken the assertion to make it pass. A count of zero is not a tolerance problem.

## Acceptance Criteria

- [ ] The cause is stated: no reuse, or no report
- [ ] `swift test --package-path IntegrationTests` is green on this suite
- [ ] The assertion still requires a positive `cachedTokenCount`, and still compares it against what turn 1 processed

#integration #real-model