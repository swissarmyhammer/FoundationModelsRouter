---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m11zb96rvevqebs5h3n7xx38
  text: |-
    ### Research

    Picked up the card and read the current tree. The line numbers on the card are stale; the symbols are all still there.

    Confirmed the three readers of `moduleName`:

    - `makeModuleLogger(category:)` in `Sources/FoundationModelsRouter/FoundationModelsRouter.swift` — `Logger(subsystem: moduleName, category: category)`. Unmoved; the card's line 23 is still correct.
    - The default transcript recordings directory in `Sources/FoundationModelsRouter/RoutedLLM.swift` — `.appendingPathComponent(moduleName, isDirectory: true)`. Unmoved; the card's line 260 is still correct.
    - The default cache directory in `Sources/FoundationModelsRouter/Router.swift`, inside `Router.defaultCacheDir()` — `base.appendingPathComponent(moduleName, isDirectory: true)`. **MOVED**: the card says line 963, the code is now at line 975.

    A fourth reader the card does not name: `assertLogged(containing:since:)` in `Tests/FoundationModelsRouterTests/Helpers/LogAssertions.swift` filters log entries on `$0.subsystem == moduleName` and puts `moduleName` into its failure message. The card's Acceptance Criteria names that helper, so this is the site those criteria are about.

    `moduleName` is declared at `Sources/FoundationModelsRouter/FoundationModelsRouter.swift:10`, which is the line the card gives.

    `Router` is a `public actor`, so `String(reflecting: Router.self)` gives `"FoundationModelsRouter.Router"` and the test can take the prefix before the first `.`.

    Read the review rules for `.swift` files before editing (54 rules over code-hygiene, code-security, completeness, duplication, reuse, swift and test-integrity).
  timestamp: 2026-08-27T16:02:47.128158+00:00
- actor: claude-code
  id: 01m11zp1ch21r2m338ra86n644
  text: |-
    ### TDD record

    The new test cannot fail against the code as it stood, because the literal and the compiler-derived name are the same string. So the red step was made by staging a wrong value: `let moduleName = "StaleOldTargetName"`.

    `swift test --filter BootstrapTests` then failed both tests, and the new one failed for the correct reason:

    ```
    moduleName == String(String(reflecting: Router.self).prefix { $0 != "." }) → false
      moduleName → "StaleOldTargetName"
      String(String(reflecting: Router.self).prefix { $0 != "." }) → "FoundationModelsRouter"
    ```

    The staged value was then replaced by the `#fileID` derivation, and the same run passed 2 tests in 1 suite.

    Note for the next agent: a type-name `--filter` (`BootstrapTests`, `GenerationStallDiagnosticTests`) does select tests and does report a real failure. A display-name filter matches nothing and exits 0, which is a false pass.

    ### Verification

    - Clean build: `rm -rf .build && swift build --build-tests 2>&1` — exit 0. The only warnings are the three pre-existing ones that are not ours: the vendored C++17 Metal header warnings from `.build/checkouts/mlx-swift`, `missing creator for mutated node: (... mlx-swift_Cmlx.bundle/Contents/MacOS)`, and a cold-checkout `'swift-nio': skipping cache` line. No warning comes from a source file of this package.
    - First full `swift test` after the cold rebuild: `GenerationStallDiagnosticTests` failed at `GenerationStallDiagnosticTests.swift:292` with a `BoundedWait.swift:114` issue under it. `swift test --filter GenerationStallDiagnosticTests` on the warm build passed all 6 tests, so this was the rebuild-contention flake, not a real failure.
    - Full warm `swift test` — exit 0: 1062 tests in 107 suites passed with the 2 pre-existing known issues, and 83 tests in 10 suites passed. The baseline was 1061 tests, so the new test added exactly one.

    The diff touches two source files only. `RoutedLLM.swift` and `Router.swift` are not edited, so their `moduleName` readers compile unchanged.
  timestamp: 2026-08-27T16:08:39.569465+00:00
- actor: claude-code
  id: 01m11zp624xc18xawwb3f4rgaw
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/FoundationModelsRouter.swift, Tests/FoundationModelsRouterTests/BootstrapTests.swift. `rm -rf .build && swift build --build-tests` exit 0, no warning from this package's own sources. `swift test` exit 0: 1062 tests / 107 suites passed with the 2 pre-existing known issues, and 83 tests / 10 suites passed.
    - next: /review
  timestamp: 2026-08-27T16:08:44.356692+00:00
- actor: claude-code
  id: 01m11zv82q5bnq8x7jb39w3ars
  text: |-
    ### test — green

    - `swift build --build-tests 2>&1` — build complete, 0 errors, only the pre-existing `missing creator for mutated node: (.../mlx-swift_Cmlx.bundle/Contents/MacOS)` warning. No warning from this package's own sources.
    - `swift test` (full suite, run twice — cold and warm): both runs identical.
      - `Test run with 1062 tests in 107 suites passed after ~5s with 2 known issues.`
      - `Test run with 83 tests in 10 suites passed.`
      - The 2 known issues are the expected pre-existing ones: `RealModelHarness.swift:72` and `BoundedWait.swift:114`.
      - Count is up 1 from the prior 1061, matching the new `BootstrapTests.moduleNameMatchesCompilerModule`, which passed. It checks `moduleName == String(String(reflecting: Router.self).prefix { $0 != "." })` — an independent derivation, not a circular compare against itself — and the prior pinned-literal test `moduleAndMLXProductsImport` (`moduleName == "FoundationModelsRouter"`) still passes.
      - Checked the `os.Logger` subsystem concern explicitly: every test that calls `assertLogged(containing:since:)` in `TranscriptEntryMapperTests`, `TranscriptReconstructionTests`, and `GenerationStallDiagnosticTests` passed on both runs, confirming the log-reading helper still finds entries now that `moduleName` is derived from `#fileID` rather than the old literal.
      - No skipped tests found (`Test run with ... passed` carries no skipped count; the two matches for the word "skip" in test names are literal test-name text, not skip markers).
    - `mcp__sah__diagnostics check working` — 0 errors, 0 warnings.
    - No changes required; build was already clean.
  timestamp: 2026-08-27T16:11:30.263552+00:00
position_column: doing
position_ordinal: '80'
title: Derive moduleName from the compiler; remove the duplicated "FoundationModelsRouter" literal
---
## What

`Sources/FoundationModelsRouter/FoundationModelsRouter.swift:10` declares `let moduleName = "FoundationModelsRouter"`. This string is a copy of the module name that the Swift package already gives the target (`Package.swift:10`, `let packageName = "FoundationModelsRouter"`, used as the target name at `Package.swift:111`). If the target is renamed, the literal stays stale and the `os.Logger` subsystem and the cache/transcript directories silently keep the old name.

The compiler already knows the module name. `#fileID` expands to `"<ModuleName>/<FileName>.swift"`, so the module name is the text before the first `/`. Replace the literal with a value derived from `#fileID`:

```swift
/// The name of this module, as the compiler sees it. Derived from `#fileID`
/// (`"Module/File.swift"`), so it stays correct if the target is renamed.
let moduleName = String(#fileID.prefix { $0 != "/" })
```

Keep the name `moduleName`, its `internal` access level and its type (`String`) unchanged. The three call sites that read it stay as they are:

- `Sources/FoundationModelsRouter/FoundationModelsRouter.swift:23` — `makeModuleLogger(category:)` (`Logger(subsystem: moduleName, ...)`)
- `Sources/FoundationModelsRouter/RoutedLLM.swift:260` — default transcript recordings directory
- `Sources/FoundationModelsRouter/Router.swift:963` — default cache directory

Update the doc comment on `moduleName` so it states where the value comes from. Do not touch `Package.swift`.

Subtasks:

- [x] Add a test in `Tests/FoundationModelsRouterTests/BootstrapTests.swift` that asserts `moduleName` equals the module part of the test's own view of a router symbol — `String(reflecting: Router.self)` is `"FoundationModelsRouter.Router"`, so take the prefix before the first `.` — so the test does not hard-code the literal either. Keep the existing `#expect(FoundationModelsRouter.moduleName == "FoundationModelsRouter")` line; it is the bootstrap anchor.
- [x] Replace the literal at `Sources/FoundationModelsRouter/FoundationModelsRouter.swift:10` with the `#fileID`-derived expression and update its doc comment.
- [x] Build and run the hermetic test suite; confirm zero warnings.

## Acceptance Criteria

- [x] `Sources/FoundationModelsRouter/FoundationModelsRouter.swift` contains no string literal `"FoundationModelsRouter"`. A `grep -n '"FoundationModelsRouter"' Sources/FoundationModelsRouter/FoundationModelsRouter.swift` returns no match.
- [x] `moduleName` still evaluates to `"FoundationModelsRouter"` at run time (the existing bootstrap assertion passes).
- [x] `makeModuleLogger(category:)`, `RoutedLLM.swift:260` and `Router.swift:963` compile unchanged.
- [x] `assertLogged(containing:since:)` in `Tests/FoundationModelsRouterTests/Helpers/LogAssertions.swift` still finds log entries under the `moduleName` subsystem — the suites that call it (`TranscriptEntryMapperTests`, `TranscriptReconstructionTests`, `GenerationStallDiagnosticTests`) stay green.

## Tests

- [x] New test `moduleNameMatchesCompilerModule` in `Tests/FoundationModelsRouterTests/BootstrapTests.swift`: `#expect(moduleName == String(String(reflecting: Router.self).prefix { $0 != "." }))`.
- [x] Run `swift build 2>&1` — expected: exit 0, zero warnings (do a clean build; a cache-hit build hides warnings).
- [x] Run `swift test` — expected: all tests pass, `BootstrapTests` includes the new test. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #cleanup