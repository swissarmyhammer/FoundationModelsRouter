---
assignees:
- claude-code
position_column: doing
position_ordinal: '80'
title: Make WatchStopUsageTests reasoning-stop usage sum stable under a parallel run
---
## Problem

The test "after a reasoning stop, the stopped call is a generation call, and its fed tokens are in the answer usage" in `Tests/FoundationModelsRouterTests/WatchStopUsageTests.swift` (helper `expectStoppedCallReported(of:finishReason:)`) failed one time in a full `swift test` run on 2026-10-09:

```
Expectation failed: usage.tokensOut == calls.map(\.tokensOut).reduce(0, +)
usage.tokensOut → 151
calls.map(\.tokensOut).reduce(0, +) → 152
```

The same suite passed alone right after (`swift test --skip-build --filter WatchStopUsageTests`, 6 of 6). The failure came during the work of ^twha0gz, which does not touch the watch, the usage or the generation call events. Thus this is an intermittent fault under load.

## Work

- Find why the sum of the `generationCall` events of the stopped answer can be one token more than `SessionAnswer.usage.tokensOut`. A probable cause: a token that the stopped call counts after the cancel of the watch, which the submission usage does not count (or the reverse).
- Correct the cause in production code or in the test fixture. Do not loosen the assertion.

## Tests

- The suite passes in each of ten full `swift test` runs.
