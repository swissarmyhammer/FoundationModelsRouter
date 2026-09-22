---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'IntegrationTests: RealToolTurnComparisonTests switch does not handle SessionEvent.generationCall'
---
`swift build --package-path IntegrationTests --build-tests` fails:

```
IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/RealToolTurnComparisonTests.swift:351:13: error: switch must be exhaustive
```

Commit 5705477 added `case generationCall(GenerationCallUsage)` to `SessionEvent`. The `switch event` at line 351 lists every other case by name and has no `default`. Add `.generationCall` to the catch-all arm of that switch. Then build the IntegrationTests package and confirm it compiles.

Found while task ^5e8g7pz built the IntegrationTests package. That task changed one comment word in this file and did not touch the switch. #compaction