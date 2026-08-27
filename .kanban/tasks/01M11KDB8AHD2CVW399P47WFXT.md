---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Replace OwningProfileBox with a Mutex-guarded weak owningProfile on RoutedModel
---
## What

`Sources/FoundationModelsRouter/LanguageModelProfile.swift:7-28` declares `OwningProfileBox`, a `@unchecked Sendable` class that wraps an `NSLock` and a `weak var stored: LanguageModelProfile?`. `RoutedModel` holds one at line 70 (`let owningProfileBox = OwningProfileBox()`), `LanguageModelProfile.init` fills it at lines 179-181, and `RoutedModel.requireOwningProfile(apiName:)` in `Sources/FoundationModelsRouter/RoutedLLM.swift:28-33` reads it back through `owningProfileBox.current`.

Why a plain `let owningProfile: LanguageModelProfile` does not work:

1. **Construction order.** `Router.resolve` builds the three `RoutedModel` handles first and then passes them into `LanguageModelProfile.init` (`Sources/FoundationModelsRouter/Router.swift:711-727`). The profile does not exist when a handle is initialized, so the back-reference must be set after the handle's `init`. `RoutedModel` is `final class ... Sendable` with only `let` storage, so a mutable slot needs a lock.
2. **Retain cycle.** The profile holds the three handles strongly (`standard`, `flash`, `embedding`). A strong back-reference would form a cycle and `LanguageModelProfile.deinit` (which releases residency through the router) would never run. The back-reference must stay weak.

So a lock-guarded weak slot is required. What is NOT required is a bespoke class with a hand-rolled `NSLock` and `@unchecked Sendable`: this module already uses `Mutex` from `Synchronization` for the same job (`Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:18`, `Sources/FoundationModelsRouter/Concurrency/RaceGate.swift:24`, `Sources/FoundationModelsRouter/Session/GenerationReentry.swift:102`).

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

- In `LanguageModelProfile.init` (lines 179-181) call `standard.registerOwningProfile(self)`, `flash.registerOwningProfile(self)`, `embedding.registerOwningProfile(self)`.
- In `Sources/FoundationModelsRouter/RoutedLLM.swift:29` read `owningProfile` instead of `owningProfileBox.current`. Keep `requireOwningProfile(apiName:)` and its trap message unchanged.
- Keep the doc comment on the retain-cycle and construction-order reasons (the two points above) on the new slot, so the next reader does not ask this question again.

Subtasks:

- [ ] Write `Tests/FoundationModelsRouterTests/OwningProfileTests.swift` (see Tests) against the new `owningProfile` / `registerOwningProfile(_:)` API; it fails to compile until the change lands.
- [ ] Replace `OwningProfileBox` in `LanguageModelProfile.swift` with the `Mutex`-guarded slot, `owningProfile` and `registerOwningProfile(_:)`; update the three `register` calls in `LanguageModelProfile.init`.
- [ ] Update `RoutedLLM.swift:29` to read `owningProfile`.
- [ ] Clean build with zero warnings, full `swift test` green.

## Acceptance Criteria

- [ ] `grep -rn OwningProfileBox Sources Tests` returns no match.
- [ ] `grep -rn "NSLock" Sources/FoundationModelsRouter/LanguageModelProfile.swift` returns no match; the file has no `@unchecked Sendable`.
- [ ] `RoutedModel.owningProfile` is `nil` for a handle built directly through `RoutedLLM.init` before a profile is built over it, is identical (`===`) to the profile for all three handles after `LanguageModelProfile.init`, and is `nil` again after the only strong reference to that profile is dropped.
- [ ] `requireOwningProfile(apiName:)` in `RoutedLLM.swift` compiles against the new property and its trap message text is unchanged.
- [ ] `HumanWaitGateTests` and `TurnCancellationTests` (which document the weak-hold behavior at `HumanWaitGateTests.swift:439` and `TurnCancellationTests.swift:770`) stay green.

## Tests

- [ ] New file `Tests/FoundationModelsRouterTests/OwningProfileTests.swift`, `@Suite("Owning profile back-reference")`, `@testable import FoundationModelsRouter`. Fixtures that already exist in `Tests/FoundationModelsRouterTests/Helpers/`:
  - container: `UndrivenLanguageModelContainer()` (`Helpers/UndrivenLanguageModel.swift:46`, a `LoadedLLMContainer` that nothing drives);
  - router: `RouterTestFixtures.makeRouter(cacheDir:loader:)` with `StubModelLoader(container:dimension:)` and `RouterTestFixtures.makeTempDir(prefix:)`, as `SharedGenerationGateContentionTests.swift:213-222` does;
  - profile: `HandBuiltProfileFixtures.makeProfile(definitionName:chosen:container:router:)` (`Helpers/HandBuiltProfileFixtures.swift:43`);
  - a bare handle: `RoutedLLM(slot: .standard, chosen:, footprintBytes: 0, resolution: SlotResolution(slot: .standard, remainingBudgetBytes: 0, chosen:, considered: []), container:, routerId: router.id, recorder: InMemoryRecorder(), gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks))` — the same call `HandBuiltProfileFixtures.makeGenerationHandle` makes at lines 114-123 (that helper is `private static`, so call `RoutedLLM.init` directly).
  Tests:
  - `handleReportsNilBeforeRegistration` — the bare `RoutedLLM` has `owningProfile == nil`.
  - `profileInitRegistersItselfOnAllThreeHandles` — after `makeProfile`, `profile.standard.owningProfile === profile`, and the same for `flash` and `embedding`.
  - `handleDropsProfileWhenProfileIsReleased` — `var profile: LanguageModelProfile? = makeProfile(...)`, `let standard = profile!.standard`, `profile = nil`, then `#expect(standard.owningProfile == nil)`.
- [ ] Run `swift build 2>&1` — expected: exit 0, zero warnings (clean build; a cache-hit build hides warnings).
- [ ] Run `swift test` — expected: all tests pass, including the three above. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #cleanup