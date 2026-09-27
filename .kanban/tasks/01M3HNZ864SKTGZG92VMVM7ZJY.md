---
assignees:
- claude-code
position_column: todo
position_ordinal: a780
title: Remove the settings-free Summarization parameter from the public session API, and keep old sidecars decoding
---
## What

`Summarization` has no settings (`Sources/FoundationModelsRouter/Compaction/Summarization.swift`: "The stage has no settings"). Since task ^pke18c2, the public API still takes it as a parameter and a stored field, only so that old sidecars decode. Remove it from the public surface. This card changes only the public surface and the sidecar. Card "Remove the stored Summarization from the session actor and the Compactor" removes the internal plumbing after this card.

Files:
- `Sources/FoundationModelsRouter/Session/SessionConfiguration.swift` — remove `public var summarization` and the `summarization:` init parameter. In `Persistable`, change `summarization` so that encoding does not write it and decoding accepts a sidecar that has it (for example `let summarization: Summarization?`, or a custom `CodingKeys` that ignores the key). Remove `summarization:` from `persistable`.
- `Sources/FoundationModelsRouter/RoutedLLM.swift` — remove `summarization:` from the public `makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)`, from `makeSession(configuration:)`, and from the internal `makeSession(grammar:...)`. Pass `Summarization()` to `makeRoutedSessionActor` for now. Update each DocC symbol link that names the old signature.
- `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift` — remove `summarization:` from `makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)`.
- `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/GuidedGeneration.md` — update the two symbol links.
- `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` (line ~481) — stop reading `configuration?.summarization`; pass `Summarization()`.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift` (line ~689) — the sidecar `SessionConfiguration(...)` loses `summarization:`.

Tests that pass `summarization:` must lose that argument: `rg -l -w summarization Tests IntegrationTests Examples Tools` lists them.

## Acceptance Criteria
- [ ] No public declaration in `Sources/` has a `summarization` parameter or property: `rg -n "summarization:" Sources/FoundationModelsRouter/RoutedLLM.swift Sources/FoundationModelsRouter/Guided Sources/FoundationModelsRouter/Session/SessionConfiguration.swift` finds no public one.
- [ ] A new sidecar does not have the `summarization` key.
- [ ] The checked-in sidecar `Tests/FoundationModelsRouterTests/Fixtures/PreRequestRenameRecording/01M3CWVB5NFSC7HFT40W63E4TX/session.json`, which has the `summarization` key, still decodes and restores.
- [ ] `swift build --build-tests` has no new warning, and `swift build --package-path IntegrationTests --build-tests` passes.

## Tests
- [ ] `Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift`: remove the `summarization` expectations (lines ~68, 85–120, 172, 189, 203). Add a test that encodes `SessionConfiguration().persistable` and expects no `summarization` key in the JSON.
- [ ] `Tests/FoundationModelsRouterTests/SessionConfigurationTests.swift`: add a test that decodes a `Persistable` JSON with a `"summarization": {}` key and expects success.
- [ ] The existing restore test that reads the `PreRequestRenameRecording` fixture still passes.
- [ ] `swift test` — all pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
- Do not run `swift format`.

#compaction