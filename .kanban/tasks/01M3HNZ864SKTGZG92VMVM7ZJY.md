---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mfbyet12dces53av4z6sek
  text: |-
    Implementation notes:
    - `SessionConfiguration.Persistable` no longer has a `summarization` property. The synthesized `Decodable` ignores a key that has no property, so an old sidecar with `"summarization": {}` still decodes. No custom `CodingKeys` is necessary.
    - `RoutedLLM.makeSession(grammar:...)` and `SessionTreeRestoration` pass `Summarization()` to `makeRoutedSessionActor`. The actor field and the `Compactor` parameter stay for the next card.
    - The DocC links to `makeSession(...)`, the internal `makeSession(grammar:...)`, `makeGuidedSession(...)` and `AutoCompactionFixtures/makeTriggeredSession(...)` no longer name `summarization:`. This includes `IntegrationTests/`.
    - The test helper `AutoCompactionFixtures.makeTriggeredSession` lost its `summarization:` parameter (no caller passed it).
    - New tests in `SessionConfigurationTests`: a new slice has no `summarization` key; a slice with the key decodes. `StoredRecoveriesKeyTests` restores the `PreRequestRenameRecording` fixture, which has the key.
    - The rule dump from `dump validators` is about 700 KB. I could not read all of it in one context.

    ### implement — changed
    - evidence: 22 files. Sources: SessionConfiguration.swift, RoutedLLM.swift, GuidedGeneration.swift, GuidedGeneration.md, SessionTreeRestoration.swift, RoutedSessionActor.swift, RoutedSession.swift, RoutedSessionActorForking.swift, DiscoveryPriming.swift. Tests: SessionConfigurationTests, SessionTreeRestorationTests, AutoCompactionFixtures, and DocC links in 7 test files and 2 IntegrationTests files. `swift build --build-tests` clean build (separate scratch path) has no warnings in repo code; `swift build --package-path IntegrationTests --build-tests` passes; 14 filtered tests pass.
    - next: /test
  timestamp: 2026-09-28T17:00:29.530792+00:00
- actor: claude-code
  id: 01m3mfry4zgy3wjfhvqnbw1n0q
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (74f8dd2) — 0 findings, 0 confirmed, 0 refuted; 14 attempted, 0 failed.
    - next: task moved to done.
  timestamp: 2026-09-28T17:07:35.199567+00:00
- actor: claude-code
  id: 01m3mfs0s9hanvffqg5gpfajdt
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 22 files; failing tests written first in SessionConfigurationTests (no summarization key in a new slice; an old slice with the key decodes).
    - test: green — `swift test`: 1362 tests in 171 suites, 20 tests in 9 suites, 19 tests in 3 suites passed (2 known issues from `withKnownIssue` blocks that were there before); clean build with a separate scratch path has no warnings in repo code; `swift build --package-path IntegrationTests --build-tests` passes.
    - commit: 74f8dd2 refactor(router)!: remove the Summarization parameter from the public session API (^mvm7zjy)
    - review: clean — review sha HEAD~1..HEAD, 0 findings.
  timestamp: 2026-09-28T17:07:37.897462+00:00
position_column: done
position_ordinal: ffffffab80
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