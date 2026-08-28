---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m135fkerh5c9w5y5hk3whg2k
  text: |-
    Research complete. What the call sites show:

    - Every reference to `SlotResolution`, `CandidateReport` and `makeResolution` is inside the root package. The nested `IntegrationTests` package names `SlotResolution` in five files, but only in comments, never in code. So `package` is wide enough everywhere.
    - `Examples/CompactionDemo/main.swift` reads `profile.standard.resolution.contextTokens` through a PLAIN `import FoundationModelsRouter`. `CompactionDemo` is an `.executableTarget` of the root package, so `package` reaches it — but `internal` would not. This holds `RoutedModel.resolution` and `SlotResolution.contextTokens` at `package`, not `internal`.
    - `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift` also uses a plain `import FoundationModelsRouter`. It calls the `SlotResolution` initializer, which is already `package`.
    - Every other reader (`JointFitTests`, `RealModelHarnessTests`, `EmbedTracingTests`, `OwningProfileTests`, `HandBuiltProfileFixtures`, `TurnCancellationTests`) uses `@testable import FoundationModelsRouter`.
    - Inside `Sources`, every signature that names the two types is `private` (Router.swift) or `internal` (JointFit.swift, ResolutionFailure). No public signature names them.
    - The two structs carry four `public let` members: `CandidateReport.ref`, `CandidateReport.chargedBytes`, `SlotResolution.considered`, `SlotResolution.contextTokens`. They go to `package` with their types, so no `public` declaration is left naming a `package` type.
    - Neither the DocC catalog nor `README.md` names `SlotResolution` or `CandidateReport`, so this change breaks no documentation link.

    Baseline `swift build` at the root is clean before the edit.
  timestamp: 2026-08-28T03:09:14.584701+00:00
- actor: claude-code
  id: 01m135rsmyb8078rfzjdbm69zy
  text: |-
    Implementation landed. Eight declarations changed from `public` to `package`:

    `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift`
    - `struct CandidateReport`
    - `CandidateReport.ref`
    - `CandidateReport.chargedBytes`
    - `struct SlotResolution`
    - `SlotResolution.considered`
    - `SlotResolution.contextTokens`

    `Sources/FoundationModelsRouter/LanguageModelProfile.swift`
    - `RoutedModel.resolution`

    `Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift`
    - `RealModelHarness.makeResolution(slot:model:context:)`

    The four members went to `package` with their types, not to `internal`: `Examples/CompactionDemo` reads `contextTokens` through a plain import, and a `public` member left inside a `package` struct would keep a `public` declaration naming a `package` type. `SlotResolution.swift` now holds no `public` at all.

    Nothing else changed. The already-`internal` fields (`slot`, `remainingBudgetBytes`, `chosen`, `verdict`, `ladderAttempts`, `estimatedFootprintBytes`) and the already-`package` initializers are untouched.

    Verification, all at the root of the repository:
    - `swift build` — Build complete, exit 0. The only warning is the pre-existing SwiftPM "missing creator for mutated node" line, which the baseline run before the edit printed too.
    - `swift test` — exit 0. 1065 tests in 108 suites passed, plus 83 tests in 10 suites in the evals target. `RealModelHarnessTests` is among them, which proves `makeResolution` kept an access level wide enough to cross the target boundary.
    - `swift build --package-path IntegrationTests` — Build complete, exit 0.
    - `swift build --package-path IntegrationTests --build-tests` — Build complete, exit 0. This is extra evidence the card did not ask for: it compiles `FoundationModelsRouterIntegrationTests` and `FoundationModelsRouterEvalIntegrationTests`, the two targets in the separate nested package, which `package` access does NOT reach. They compile, so no code there reads the demoted symbols.

    The second acceptance criterion has a compiler proof, not only a text search: Swift refuses to compile a `public` declaration whose signature names a `package` type. The build is clean, so no public signature in the module names either type.
  timestamp: 2026-08-28T03:14:15.838793+00:00
- actor: claude-code
  id: 01m135wqeak0djpz15n5b8jfqf
  text: |-
    Checked one risk the validator rules name, rather than assuming it away.

    `dead-code-swift` runs periphery with `--retain-public`, and that flag retains a `public` or an `open` declaration only. It names no third level. So each symbol this card demotes leaves the exemption and enters the dead-code gate. `Tests/FoundationModelsRouterRealModelSupport` is a plain `.target`, not a `.testTarget`, so the rule's `--report-exclude` for test targets does not cover `makeResolution` either.

    Measured, not reasoned: periphery 3.8.0, after `swift build --build-tests`, with the rule's own flag set (`--retain-public`, `--retain-objc-accessible`, `--retain-swift-ui-previews`, `--retain-codable-properties`, `--relative-results`, and one `--report-exclude` for each of the two test targets), dropping the `var.parameter` kind the rule drops.

    Result: 0 findings. Every demoted symbol has a caller the index can see, and no stored property reads as assign-only. No `// periphery:ignore` marker is needed anywhere.

    Two other rule facts, recorded so the review does not have to find them again:
    - `missing-docs-swift` runs swiftlint with `warning: [open, public]`, so a `package` declaration is outside that gate. Each demoted declaration keeps the doc comment it already carried, so this changes nothing either way.
    - `public-output-contract` will show a `visibility changed` probe row for each of the eight declarations. Its own exception covers them: "The task explicitly asked to change the message/output/format, or to change the declaration the probe row names." This card is that ask.
  timestamp: 2026-08-28T03:16:24.650795+00:00
- actor: claude-code
  id: 01m135wwx5kjfw7td9kx27g6yc
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Resolution/SlotResolution.swift, Sources/FoundationModelsRouter/LanguageModelProfile.swift, Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift. Eight `public` to `package`. `swift build` exit 0; `swift test` exit 0 with 1065 tests in 108 suites plus 83 tests in 10 suites; `swift build --package-path IntegrationTests` exit 0; `swift build --package-path IntegrationTests --build-tests` exit 0; periphery scan 0 findings.
    - next: /review
  timestamp: 2026-08-28T03:16:30.245548+00:00
- actor: claude-code
  id: 01m1363c8m5ryh2d5fh8a9r25r
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 7217de7) — 0 findings, 0 confirmed, 0 refuted, 7 validator runs attempted, 0 failed. 3 files reviewed. 2 `.kanban/` files not reviewed, because a `.reviewignore` rule excludes them.
    - next: the task moves to `done`. All acceptance criteria and test items are checked.
  timestamp: 2026-08-28T03:20:02.580850+00:00
- actor: claude-code
  id: 01m1363ykmr9sqxs1xg5k9gpdq
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files (SlotResolution.swift, LanguageModelProfile.swift, RealModelHarness.swift)
    - test: green — swift test, 1065 tests in 108 suites passed, plus 83 tests in 10 suites
    - commit: 7217de7
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - next: none — the task is in done
  timestamp: 2026-08-28T03:20:21.364179+00:00
position_column: done
position_ordinal: ffff9080
title: Demote SlotResolution and CandidateReport to package
---
## What

Split out of the Session and Recording demotion task, because this is a separate access-level policy call on a separate subsystem.

`SlotResolution` (Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:89) and `CandidateReport` (line 51) are public only because `RoutedModel.resolution` (Sources/FoundationModelsRouter/LanguageModelProfile.swift:28) is public. No test, example, or tool reads `CandidateReport`, and the type's own fields `verdict` and `ladderAttempts` (SlotResolution.swift:66, 70) are already internal.

- Demote `SlotResolution` and `CandidateReport` to `package`.
- Demote `RoutedModel.resolution` to `package`.
- Demote `RealModelHarness.makeResolution(...)` (Tests/FoundationModelsRouterRealModelSupport/RealModelHarness.swift:92) to `package`, NOT to `internal`. `FoundationModelsRouterRealModelSupport` is a plain `.target` (Package.swift:208), and `Tests/FoundationModelsRouterTests/RealModelHarnessTests.swift` reaches it through a plain `import` at lines 82 and 106; `internal` does not cross a target boundary and would break the build. No file in the nested `IntegrationTests` package calls `makeResolution`, so `package` is safe.

## Acceptance Criteria
- [x] The three router symbols and `makeResolution` are `package`.
- [x] No public signature in the module names `SlotResolution` or `CandidateReport`.

## Tests
- [x] Run `swift build` and `swift test` at the root. All targets build and all tests pass. `RealModelHarnessTests` compiling is the proof that `makeResolution` kept a wide enough access level.
- [x] Run `swift build --package-path IntegrationTests`. It builds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup