---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzw7e8d1w3bygexe90vbb85h
  text: |-
    Research notes:
    - `ResolutionProgress` is `@MainActor @Observable` (Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift). The router mutates `phase` only on the main actor (Router.swift, "Progress mutations (main actor)"). Thus an observation chain with `withObservationTracking` plus a re-armed `@MainActor` task gives a correct AsyncStream bridge with no polling.
    - `RoutedModel` holds `routerId` and `recordingsRoot` (Sources/FoundationModelsRouter/LanguageModelProfile.swift). `restoreSessionTree` (Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift) computes `<recordingsRoot>/<routerId>/` and throws `SessionTreeRestorationError.noDurableRecordingsRoot` when the root is nil. The new `transcriptTree(recordingRoot:)` will own that computation and `restoreSessionTree` will call it.
    - The repo has no usage markdown that shows the polling loop or the path math. docs/Usage.md covers only RoutedSession surfaces. README.md shows no polling loop. The living usage guide is Tests/FoundationModelsRouterTests/ExamplesTests.swift (README points to it). I will update the progress example there to the `for await` form.
    - Test helpers to reuse: RouterTestFixtures.makeRouter/makeTempDir/profile/stubDimension, UndrivenLanguageModelContainer, JSONLRecorder, BoundedWait (bounded spin, no sleep-poll).
    - Validator rules read from the dump: doc `- Parameter` keys use internal names; every public declaration gets `///` docs; no force unwrap or `try!` outside tests; magic numbers need named constants (0, 1, -1, 100 allowed); exhaustive switches over domain enums; reuse shared helpers.
  timestamp: 2026-08-13T00:13:04.801521+00:00
- actor: claude-code
  id: 01kzw8ezn6d760ynv3q1km3gv8
  text: |-
    ### implement — changed
    - evidence: 8 files. New API: `ResolutionProgress.phases` (Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift) — an `AsyncStream` of `(phase, fraction)` transitions from `withObservationTracking`, no polling; yields the current phase first, yields each observed change once, and finishes at `.ready`/`.failed`. New API: `RoutedModel.transcriptTree(recordingRoot:)` (Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift) — returns the loaded `TranscriptTree`, throws `SessionTreeRestorationError.noDurableRecordingsRoot` when the router records to memory; `restoreSessionTree` now calls it instead of repeating the path math. TDD-first tests: Tests/FoundationModelsRouterTests/ResolutionProgressPhasesTests.swift (3 tests: each transition once + terminate at .ready, terminate at .failed, late subscriber gets one terminal element) and Tests/FoundationModelsRouterTests/TranscriptTreeAccessTests.swift (3 tests: nested layout, explicit flat recordingRoot, typed error) — both watched fail (compile error: member missing) before the implementation. Examples: both polling blocks replaced with a `for await` loop that prints the same `[resolve] phase=... fraction=...%` lines; CompactionDemo's hand-built `recordingsDir/<routerId>` path replaced with `profile.standard.transcriptTree()`. Usage docs: ExamplesTests `resolveProfileObservingProgress` and the README quickstart show the `phases` form. docs/Usage.md was not changed: it covers only the RoutedSession surfaces, states that all its output is captured from runs, and never showed the polling loop or the path math — there was no old form there to replace. Verification: `swift build --build-tests` clean; ONE ungated `swift test` run: 906 + 27 + 24 tests passed, 0 failures (the 1 "known issue" is BoundedWaitTests' own deliberate pre-existing marker).
    - next: /review
  timestamp: 2026-08-13T00:30:57.190631+00:00
position_column: doing
position_ordinal: '8180'
title: 'Example ergonomics: progress as an AsyncSequence, tree access off the profile'
---
## Problem

Two pieces of boilerplate repeat in every example, so every new user will copy them:

1. **Progress polling.** `ResolutionProgress` is `@Observable`, designed for SwiftUI binding. A CLI caller must write a fifteen-line polling `Task` with a sleep loop to print phase transitions — both examples carry the identical block (Examples/MultiModelGeneration/main.swift:58-73, Examples/CompactionDemo/main.swift:128-143).
2. **Recording path math.** The CompactionDemo composes the router directory by hand — `recordingsDir.appendingPathComponent(profile.standard.routerId.description)` — to load a `TranscriptTree` (Examples/CompactionDemo/main.swift:271-273). User code should never build recording paths from parts; the layout is the router's private convention.

## Proposed solution

1. Add an `AsyncSequence` view of resolution progress — for example `progress.phases` yielding each `(phase, fraction)` transition and finishing at `.ready`/`.failed`. The `@Observable` surface stays for SwiftUI; the sequence serves CLI and tests. Both examples shrink to a three-line `for await` loop.
2. Add tree access to the profile or the routed model — for example `profile.standard.transcriptTree()` returning the loaded `TranscriptTree` for this router's recording root (and throwing the existing typed errors). The CompactionDemo's path math is deleted.
3. Update both examples and the Usage guide to the new forms — the examples are the product's first impression, and they must show the shortest correct code.

## Acceptance

- Neither example contains a polling loop or a hand-built recording path.
- The `for await` progress loop prints the same phase transitions the polling loop printed.
- `ExamplesTests` stays green. #api