---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m062d0145czve5wdvy24m0gc
  text: |-
    Research, and the option chosen.

    Read the three options against the code. Chose **option 1 — remove the gate from the public initializer** — and took it to its full form: the whole handle/profile construction path leaves the public surface.

    What the code showed:
    - The public initializer named on the card is `RoutedModel.init`, in `LanguageModelProfile.swift`. `LanguageModelProfile.init` was public beside it, and the two together are what build a hand-made graph.
    - Production has exactly ONE construction site of each: `Router.makeRoutedModel` and `Router.resolve`. Every other site is a test.
    - Every test target that builds a handle already writes `@testable import FoundationModelsRouter`, so making both initializers internal broke no test import.
    - Nothing under `Examples/` builds a handle or a profile, and `FoundationModelsMultitool` reported the same. So no known consumer loses anything.

    Why not option 2 (the gate comes from the container). `LoadedLLMContainer` is a public protocol with dozens of conformers in this repo alone, many of them `struct`s, and it is open to a consumer's own container. A `generationGate` requirement on it is a public protocol break for every conformer, and it puts a router throughput concept into the generation seam. The alternative — a registry keyed on container identity — cannot work: `LoadedModelContainer` refines `Sendable` only, so a struct conformer has no stable identity and the registry would mint a second gate for exactly the case it exists to catch. That silence is the defect being removed, so a fix that reproduces it is not a fix.

    Why not option 3 (warn). Detecting "two handles, one container" needs the same container identity option 2 needs, so the warning is silent for a value-type container. And a warning leaves the wrong object graph reachable; the card asks which behaviour is correct, not for a notice about the incorrect one.

    The silent default was the real defect. `generationGate`/`forkAdmissionGate` each defaulted to `nil`, and `nil` minted a fresh gate. A caller who said nothing got a second set and no signal. The two gates are now one required `ResidentModelGates` value with no default, so every construction states which resident container's set it joins. `maxConcurrentForks` left `RoutedModel.init` with it: it only ever sized a gate the initializer minted, and the initializer mints none now.
  timestamp: 2026-08-16T19:57:24.900395+00:00
- actor: claude-code
  id: 01m062dhfjgbf2vxv4t1tkrjz3
  text: |-
    What landed, and the public API break.

    New type `Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift` — internal, `Sendable`, holding `generation` and `forkAdmission`. One resident container carries one set. `init(maxConcurrentForks:)` mints a fresh set for a container that has just become resident.

    `RoutedModel.init` is now internal and takes `gates: ResidentModelGates` with NO default, in place of `maxConcurrentForks` / `generationGate:` / `forkAdmissionGate:`. `LanguageModelProfile.init` is now internal. Both doc comments state the hazard plainly, and the "e.g. in tests" wording is gone.

    `Router.PoolEntry` holds one `gates: ResidentModelGates` in place of the two separate gates, minted at first load and handed to every handle over that entry — the same behaviour as before, stated as one value.

    THIS IS A PUBLIC API BREAK. Two initializers left the public surface:
    - `RoutedModel.init(slot:chosen:footprintBytes:resolution:container:routerId:recorder:durableRecording:maxConcurrentForks:generationGate:forkAdmissionGate:)`
    - `LanguageModelProfile.init(definitionName:standard:flash:embedding:router:residencyToken:)`

    A consumer who built a handle or a profile by hand must now go through `Router.resolve(profile:reporting:)`. `AsyncSemaphore` stays public: it is a general primitive, and it was only a hazard because a public initializer accepted one. Two gated suites and one eval support file use it directly for their own serial gates, through a plain (not `@testable`) import.

    The control test is inverted, not deleted. `twoHandBuiltHandlesOverOneContainerNeverContend` is now `twoHandBuiltHandlesOverOneContainerContend`, and its doc comment records what it used to assert and why that was the defect. Both it and `twoSessionsOverOneSharedPoolEntryContend` now run the one shared drill `expectGenerationsSerialize(over:observer:latch:)`: the resolved graph and the hand-built graph owe the same contract, so writing the drill twice would let the two copies drift. The asymmetry the suite recorded is gone, which is the proof.

    `HandBuiltProfileFixtures.makeProfile` lost its `generationGate` parameter. It mints one set for the one generation container and gives it to both generation handles; the embedding stub gets its own. A test can no longer ask for the two-gate shape.

    The six gated suites the card names, plus the eval runner, now mint one set for their one container and share it across `standard` and `flash`, each with a comment stating why. They keep the hand-built path: each drives ONE real model, and the resolver path would download three.

    TDD record. Flipped the control's identity assertion first and watched it fail (1 issue, `swift test --filter SharedGenerationGateContentionTests`), then implemented, then watched all 3 pass.
  timestamp: 2026-08-16T19:57:42.770055+00:00
- actor: claude-code
  id: 01m062ey34j71tv6wg59zyw4rt
  text: |-
    ### implement — changed
    - evidence: 12 files — Sources/FoundationModelsRouter/Concurrency/ResidentModelGates.swift (new), Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/Router.swift, Tests/FoundationModelsRouterTests/SharedGenerationGateContentionTests.swift, Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift, Tests/FoundationModelsRouterIntegrationTests/{RecordingHandleIntegrationTests,CompactionRoundTripIntegrationTests,RealToolTurnComparisonTests,TranscriptReconstructionIntegrationTests,LanguageModelSessionBackendTests,SessionTreeRestorationIntegrationTests}.swift, Tests/FoundationModelsRouterEvals/Support/CompactionContinuityEvalRealSubjectRunner.swift. `swift build --build-tests` clean, every target including the `Examples/` executables. `swift test` green — 963 + 27 + 24 tests, 0 failures, 0 warnings, 1 pre-existing known issue in `BoundedWait`'s own timeout self-test.
    - next: /review
  timestamp: 2026-08-16T19:58:28.452408+00:00
position_column: doing
position_ordinal: '80'
title: The public LanguageModelProfile initializer lets a consumer defeat per-container serialization
---
A consumer can build two handles over one resident container and get two separate generation gates. Two gates over one container permit two concurrent generations. That is the exact condition the gate exists to prevent.

This is the reverse of the deadlock on `^1zt7vyg`. That card is a liveness failure — something that must run does not. This card is a safety failure — something that must not run concurrently can.

## How a consumer reaches it

- `LanguageModelProfile.init(...)` is `public` and takes `generationGate: AsyncSemaphore? = nil` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:178`, `:188`).
- `AsyncSemaphore` is `public`, and `init(value:)` is `public` (`Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:32`, `:47`).
- When the parameter is `nil`, the initializer mints a fresh gate (`LanguageModelProfile.swift:199`).

The resolver path is safe. `Router` gives the same gate instance to every handle over one `PoolEntry` (`Router.swift:953`), so resolved handles contend correctly.

The direct path is not safe. Nothing makes a consumer supply the container's own gate, and nothing tells them one exists.

## Why the documentation does not protect us

`LanguageModelProfile.swift:136-137` says the fresh gate matches "the pre-pooling behavior for a handle constructed directly (e.g. in tests)". "e.g. in tests" is guidance, not a constraint. The type does not enforce it, and the initializer is public.

Six of our own gated suites already build `standard` and `flash` handles over one container this way and pass no gate. If our own suites take the unsafe path by default, a consumer will.

## Why nobody has reported it

The `FoundationModelsMultitool` session checked their tree and found no construction of a profile, a handle, or a semaphore. Every handle they hold comes from `router.resolve(profile:reporting:)`.

They ask that this is not recorded as care. They only ever needed a resolved profile. Nobody weighed the alternative. A consumer that reaches for the public initializer to avoid resolution — a test double, a fixed pin, or a warm handle held across resolutions — lands here with no warning.

## Note on the risk

The gate is a throughput constraint, not a safety constraint. See `^1zt7vyg` for that evidence, and note that Apple's `ModelContainer` gives exclusive access below us. So two concurrent generations queue at the container. They do not corrupt state.

Do not use that to close this card. Two handles over one container silently lose the serialization the gate exists to give, and the consumer gets no signal. Decide the correct behaviour deliberately rather than by default.

## Options to weigh

- Remove `generationGate` from the public initializer, and give tests a separate entry point.
- Keep the parameter but make the gate come from the container, so a direct handle shares it.
- Keep it and give a clear warning when two handles over one container hold different gates.

## Decision

Option 1, taken to its full form. `RoutedModel.init` and `LanguageModelProfile.init` are now `internal`, so `Router.resolve(profile:reporting:)` is the one way a consumer obtains a handle or a profile, and it always hands every handle over one resident container that container's own gates. The gates became one required `ResidentModelGates` value with no default, so no construction — inside the module or in a suite — can mint a second set by saying nothing. This is a public API break; the comments record it.

## Acceptance Criteria

- [x] Recorded which behaviour is correct for a directly constructed handle over an already-resident container
- [x] A consumer cannot silently obtain two gates over one container, or is warned when they do
- [x] The "e.g. in tests" wording becomes a constraint, or the documentation states the hazard plainly
- [x] Our own gated suites use the resolver path, or state why a hand-built handle is correct for that test
- [x] A test covers the two-handles-one-container case

Related: `^1zt7vyg` (the deadlock), `^trwcs63` (the coverage gap that hid both). #api #bug #nested-generation