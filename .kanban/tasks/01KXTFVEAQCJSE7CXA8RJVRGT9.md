---
assignees:
- claude-code
depends_on:
- 01KXTFTPY5BCXGN9MFXFFSJQHA
- 01KXTFV39FC09ZS0CZ1X3NGGMX
position_column: todo
position_ordinal: '8980'
title: Examples/CompactionDemo + gated end-to-end round-trip test
---
## What
Prove the loop end to end (compaction_plan.md §4): a small executable `Examples/CompactionDemo/main.swift` beside `Examples/MultiModelGeneration` (add the target to `Package.swift`):

1. Resolve a profile; open a `RoutedSession`.
2. Drive scripted long turns (reading fixture files into the conversation) while printing `contextFill` after each — watch it climb.
3. At the 0.80 trigger, call `session.compact()` — print the `CompactionResult` (tokens before/after, stages) and the summary text.
4. Continue the conversation; show the model still answers questions about pre-fold facts (from the summary) and that `session.id` is unchanged.
5. Restore with `restoreSessionTree`; show the restored transcript is the checkpointed live window, then print the `fullHistory` view to show nothing was lost.

Plus the gated real-model round-trip test (compaction_plan.md §5) in `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift`, under `FM_ROUTER_INTEGRATION_TESTS`, asserting the same five-step loop the demo prints: fill climbs across turns → compact at trigger shrinks fill and preserves `session.id` → post-compact turn succeeds → restore yields the checkpointed window → a further turn succeeds; nothing rests on a human reading stdout.

## Acceptance Criteria
- [ ] `swift build` of the CompactionDemo target succeeds in CI without a model present
- [ ] The gated integration test asserts all five demo steps mechanically (fill climb, compact result + id stability, post-compact turn, checkpointed restore, post-restore turn) with real measured token counts
- [ ] Demo source exercises the same five steps for humans running it by hand (no acceptance depends on that run)

## Tests
- [ ] `Tests/FoundationModelsRouterIntegrationTests/CompactionRoundTripIntegrationTests.swift` — passes with `FM_ROUTER_INTEGRATION_TESTS=1`
- [ ] If `Tests/FoundationModelsRouterTests/ExamplesTests.swift` compiles/checks example sources, extend it to cover CompactionDemo; `swift build` of all targets passes in CI

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #compaction