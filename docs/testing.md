# Tests

The tests are split by what they need, and the split is a package boundary
rather than an environment variable or a name filter. The root package
declares no integration target, so a plain `swift test` runs only the
hermetic tests by construction. The real-model targets live in the nested
[`IntegrationTests/`](../IntegrationTests) package.

```sh
# Everyday: hermetic, no network, no GPU, seconds.
swift test

# Real models: downloads weights and generates on the GPU. Tens of minutes.
swift test --package-path IntegrationTests

# The real-model smoke tier alone — does compaction work at all? Seconds.
swift test --package-path IntegrationTests --filter 'CompactionSmokeIntegrationTests|AutoCompactionTriggerIntegrationTests|RecordedTranscriptCompactionIntegrationTests'
```

`FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`
hold every suite that reaches a real model, and no suite in either one reads an
environment variable or can skip itself. Both targets exist only in the nested
package, so a root `swift test` cannot see them, and a run of the nested
package executes every suite in it — no command can silently match nothing.
CI runs the same two commands.

Every public API has a worked example in
[`Tests/FoundationModelsRouterTests/ExamplesTests.swift`](../Tests/FoundationModelsRouterTests/ExamplesTests.swift):
resolution, sessions, streaming, guided (grammar-constrained) generation,
embeddings, forking, and residency.
