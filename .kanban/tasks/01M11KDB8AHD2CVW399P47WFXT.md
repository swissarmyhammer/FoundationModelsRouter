---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1205gd06r7bdtzf6kwvt6p6
  text: |-
    Picked up the card. Research notes (all line numbers in the card are stale; I found each site by symbol name):

    - `OwningProfileBox` is at the top of `Sources/FoundationModelsRouter/LanguageModelProfile.swift`. `RoutedModel` holds `let owningProfileBox = OwningProfileBox()`. `LanguageModelProfile.init` calls `standard/flash/embedding.owningProfileBox.register(profile: self)`. `RoutedLLM.requireOwningProfile(apiName:)` reads `owningProfileBox.current`.
    - `RoutedModel` now also holds a `tracer` stored property and a defaulted `tracer:` initializer parameter (card ^026kke5). I do not touch it.
    - `Mutex` from `Synchronization` is the prevailing pattern in this module: `Concurrency/RaceGate.swift`, `Concurrency/AsyncSemaphore.swift`, `Session/GenerationReentry.swift`.
    - The lifetime test is deterministic: `LanguageModelProfile.deinit` copies `router` and `residencyToken` into its `Task` and never captures `self`, so nothing holds the profile after the last strong reference goes. The weak slot is zeroed inside `deinit`, before the task runs. `Router.release(token:)` returns early on a token it does not know, so a hand-built profile's release is a no-op.
    - Test fixtures confirmed present: `RouterTestFixtures.makeTempDir(prefix:)`, `RouterTestFixtures.makeRouter(cacheDir:loader:)`, `StubModelLoader(container:dimension:)`, `RouterTestFixtures.stubDimension`, `UndrivenLanguageModelContainer()`, `HandBuiltProfileFixtures.makeProfile(definitionName:chosen:container:router:)`, `defaultMaxConcurrentForks`, `InMemoryRecorder`.
  timestamp: 2026-08-27T16:17:06.464757+00:00
- actor: claude-code
  id: 01m120pdjn1z4tbm64nzqh2njc
  text: |-
    Implementation landed, through the TDD cycle.

    RED: `Tests/FoundationModelsRouterTests/OwningProfileTests.swift` was written first. `swift build --build-tests` failed with `value of type 'RoutedLLM' has no member 'owningProfile'` at the three assertion sites -- the correct failure, because the member did not exist.

    GREEN: `OwningProfileBox` is gone. `LanguageModelProfile.swift` now declares a file-private `struct WeakProfile: Sendable` that holds the weak reference, and `RoutedModel` holds `private let owningProfileSlot = Mutex(WeakProfile())` with `var owningProfile` and `func registerOwningProfile(_:)` over it. The doc comment on the slot states both reasons the shape is required: the slot is filled after the handle's initializer because `Router.resolve` builds the handles before the profile, and the reference is weak because the profile holds the handles strongly and its `deinit` must run. `LanguageModelProfile.init` calls `registerOwningProfile(self)` on all three handles. `RoutedLLM.requireOwningProfile(apiName:)` reads `guard let owningProfile`, which matches the `guard let recordingsRoot` shape already in that file; its trap message is untouched.

    Notes for the next agent:

    - The release test needs no waiting and no clock. `deinit` clears the weak slot as the profile is deallocated, and the `Task` `deinit` starts captures the router and the token only. The test asserts `=== profile` before it drops the reference, so it cannot pass vacuously.
    - `makeBareHandle` calls `RoutedLLM.init` and does not reuse `HandBuiltProfileFixtures.makeGenerationHandle`. That helper stays `private` on purpose: it mints one `ResidentModelGates` set for the one container and gives it to both generation handles, which is the one-gate rule card ^fmet68k closed a defect to establish. The reason is written in the helper's doc comment so a reader does not read the shape as a copy.
    - Two rule-driven corrections were made to the new test after the first green: `profile!` became `try #require(profile?.standard)`, which is the prevailing form in this target (383 uses), and `withStubRouter` lost a generic return type no caller used.
    - `GenerationStallDiagnosticTests`, `HumanWaitGateTests` and `TurnCancellationTests` each flaked once during this work, always at `BoundedWait.swift:114` ("never observed inside the bound") and always while a background agent loaded the machine. Every one of them passed on a warm, quiet re-run. Do not read a `BoundedWait` timeout as a real failure without a second run.
  timestamp: 2026-08-27T16:26:20.629858+00:00
- actor: claude-code
  id: 01m120pmgntqvjndxfecje581a
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/LanguageModelProfile.swift, Sources/FoundationModelsRouter/RoutedLLM.swift, Tests/FoundationModelsRouterTests/OwningProfileTests.swift (new). `swift build --build-tests` exit 0, no warning from this package's own sources (the only line is the pre-existing `missing creator for mutated node` from the mlx-swift bundle). `swift test` exit 0: 1065 tests / 108 suites pass with the 2 pre-existing known issues (RealModelHarness.swift:72, BoundedWait.swift:114), plus 83 tests / 10 suites. The count rose from 1062/107 by the 3 new tests in 1 new suite. `mcp__sah__diagnostics check working`: 0 errors, 0 warnings. `grep OwningProfileBox` over the repository: no match. `grep NSLock` and `@unchecked Sendable` in LanguageModelProfile.swift: no match.
    - next: ready for /review. The task stays in `doing`.
  timestamp: 2026-08-27T16:26:27.733395+00:00
- actor: claude-code
  id: 01m120vw4d3ewv8fr66kk1b93n
  text: |-
    ### test — green

    - Build: `swift build --build-tests 2>&1` — exit 0, zero warnings from this package's own sources on a forced recompile (touched the 3 changed files to defeat cache-hit masking). Only the known pre-existing `mlx-swift_Cmlx.bundle` warning remained.
    - Test (run 1): `swift test` — 1065 tests in 108 suites passed with 2 known issues (RealModelHarness.swift:72, BoundedWait.swift:114 — both pre-existing and expected), plus 83 tests in 10 suites passed. 0 failures, 0 skipped.
    - Test (run 2, re-run to rule out flake under load): same command, same result — 1065/108 passed with the same 2 known issues, plus 83/10 passed. No difference between runs.
    - New suite `Owning profile back-reference` (`Tests/FoundationModelsRouterTests/OwningProfileTests.swift`) passed in both runs, all 3 tests.
    - Lifetime-sensitive suites confirmed green in both runs: `Profile lifecycle + embedding access`, `Human waits release the per-model generation gate, never the per-session turn lock` (HumanWaitGateTests), `In-flight turn cancellation reaches the model call, and the tools inside it` (TurnCancellationTests), `Generation stall diagnostic`, `BoundedWait ends every wait on a wall clock, never on a count of scheduler hops`.
    - `grep -rn OwningProfileBox Sources Tests` — no match.
    - `grep -rn "NSLock\|@unchecked Sendable" Sources/FoundationModelsRouter/LanguageModelProfile.swift` — no match.
    - Counts match the expected 1065/108 + 83/10, up from 1062/107 by the 3 new tests.

    next: hand off to review.
  timestamp: 2026-08-27T16:29:19.373908+00:00
position_column: doing
position_ordinal: '80'
title: Replace OwningProfileBox with a Mutex-guarded weak owningProfile on RoutedModel
---
## What

`Sources/FoundationModelsRouter/LanguageModelProfile.swift` declared `OwningProfileBox`, a `@unchecked Sendable` class that wraps an `NSLock` and a `weak var stored: LanguageModelProfile?`. `RoutedModel` held one, `LanguageModelProfile.init` filled it, and `RoutedModel.requireOwningProfile(apiName:)` in `Sources/FoundationModelsRouter/RoutedLLM.swift` read it back through `owningProfileBox.current`.

Why a plain `let owningProfile: LanguageModelProfile` does not work:

1. **Construction order.** `Router.resolve` builds the three `RoutedModel` handles first and then passes them into `LanguageModelProfile.init`. The profile does not exist when a handle is initialized, so the back-reference must be set after the handle's `init`. `RoutedModel` is `final class ... Sendable` with only `let` storage, so a mutable slot needs a lock.
2. **Retain cycle.** The profile holds the three handles strongly (`standard`, `flash`, `embedding`). A strong back-reference would form a cycle and `LanguageModelProfile.deinit` (which releases residency through the router) would never run. The back-reference must stay weak.

So a lock-guarded weak slot is required. What is NOT required is a bespoke class with a hand-rolled `NSLock` and `@unchecked Sendable`: this module already uses `Mutex` from `Synchronization` for the same job (`Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift`, `Sources/FoundationModelsRouter/Concurrency/RaceGate.swift`, `Sources/FoundationModelsRouter/Session/GenerationReentry.swift`).

Change:

- Delete `OwningProfileBox` from `Sources/FoundationModelsRouter/LanguageModelProfile.swift`.
- On `RoutedModel`, replace `let owningProfileBox = OwningProfileBox()` with a `Mutex`-guarded weak slot and two members that state the intent directly:

```swift
import Synchronization

/// A weak reference in a `Sendable` shape, so `Mutex` can hold it.
private struct WeakProfile: Sendable {
    weak var profile: LanguageModelProfile?
}

// in RoutedModel:
/// The weak back-reference to the profile that owns this model. Weak, because
/// the profile holds this handle strongly and its `deinit` must run. Set after
/// `init`, because `Router.resolve` builds the handle before the profile.
private let owningProfileSlot = Mutex(WeakProfile())

/// The owning profile if it is still alive, else `nil`.
var owningProfile: LanguageModelProfile? {
    owningProfileSlot.withLock { $0.profile }
}

/// Records the owning profile. Called once from `LanguageModelProfile.init`.
func registerOwningProfile(_ profile: LanguageModelProfile) {
    owningProfileSlot.withLock { $0.profile = profile }
}
```

- In `LanguageModelProfile.init` call `standard.registerOwningProfile(self)`, `flash.registerOwningProfile(self)`, `embedding.registerOwningProfile(self)`.
- In `Sources/FoundationModelsRouter/RoutedLLM.swift` read `owningProfile` instead of `owningProfileBox.current`. Keep `requireOwningProfile(apiName:)` and its trap message unchanged.
- Keep the doc comment on the retain-cycle and construction-order reasons (the two points above) on the new slot, so the next reader does not ask this question again.

Subtasks:

- [x] Write `Tests/FoundationModelsRouterTests/OwningProfileTests.swift` (see Tests) against the new `owningProfile` / `registerOwningProfile(_:)` API; it fails to compile until the change lands.
- [x] Replace `OwningProfileBox` in `LanguageModelProfile.swift` with the `Mutex`-guarded slot, `owningProfile` and `registerOwningProfile(_:)`; update the three `register` calls in `LanguageModelProfile.init`.
- [x] Update `RoutedLLM.swift` to read `owningProfile`.
- [x] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [x] `grep -rn OwningProfileBox Sources Tests` returns no match.
- [x] `grep -rn "NSLock" Sources/FoundationModelsRouter/LanguageModelProfile.swift` returns no match; the file has no `@unchecked Sendable`.
- [x] `RoutedModel.owningProfile` is `nil` for a handle built directly through `RoutedLLM.init` before a profile is built over it, is identical (`===`) to the profile for all three handles after `LanguageModelProfile.init`, and is `nil` again after the only strong reference to that profile is dropped.
- [x] `requireOwningProfile(apiName:)` in `RoutedLLM.swift` compiles against the new property and its trap message text is unchanged.
- [x] `HumanWaitGateTests` and `TurnCancellationTests` (which document the weak-hold behavior) stay green.

## Tests

- [x] New file `Tests/FoundationModelsRouterTests/OwningProfileTests.swift`, `@Suite("Owning profile back-reference")`, `@testable import FoundationModelsRouter`. Fixtures that already exist in `Tests/FoundationModelsRouterTests/Helpers/`:
  - container: `UndrivenLanguageModelContainer()` (a `LoadedLLMContainer` that nothing drives);
  - router: `RouterTestFixtures.makeRouter(cacheDir:loader:)` with `StubModelLoader(container:dimension:)` and `RouterTestFixtures.makeTempDir(prefix:)`, as `SharedGenerationGateContentionTests` does;
  - profile: `HandBuiltProfileFixtures.makeProfile(definitionName:chosen:container:router:)`;
  - a bare handle: `RoutedLLM(slot: .standard, chosen:, footprintBytes: 0, resolution: SlotResolution(slot: .standard, remainingBudgetBytes: 0, chosen:, considered: []), container:, routerId: router.id, recorder: InMemoryRecorder(), gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks))` — the same call `HandBuiltProfileFixtures.makeGenerationHandle` makes (that helper is `private static`, so call `RoutedLLM.init` directly).
  Tests:
  - `handleReportsNilBeforeRegistration` — the bare `RoutedLLM` has `owningProfile == nil`.
  - `profileInitRegistersItselfOnAllThreeHandles` — after `makeProfile`, `profile.standard.owningProfile === profile`, and the same for `flash` and `embedding`.
  - `handleDropsProfileWhenProfileIsReleased` — `var profile: LanguageModelProfile? = makeProfile(...)`, `let standard = profile!.standard`, `profile = nil`, then `#expect(standard.owningProfile == nil)`.
- [x] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [x] Run `swift test` — expected: all tests pass, including the three above. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #cleanup