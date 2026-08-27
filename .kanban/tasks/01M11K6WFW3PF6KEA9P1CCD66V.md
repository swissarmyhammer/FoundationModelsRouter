---
assignees:
- claude-code
position_column: todo
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

- [ ] Add a test in `Tests/FoundationModelsRouterTests/BootstrapTests.swift` that asserts `moduleName` equals the module part of the test's own view of a router symbol — `String(reflecting: Router.self)` is `"FoundationModelsRouter.Router"`, so take the prefix before the first `.` — so the test does not hard-code the literal either. Keep the existing `#expect(FoundationModelsRouter.moduleName == "FoundationModelsRouter")` line; it is the bootstrap anchor.
- [ ] Replace the literal at `Sources/FoundationModelsRouter/FoundationModelsRouter.swift:10` with the `#fileID`-derived expression and update its doc comment.
- [ ] Build and run the hermetic test suite; confirm zero warnings.

## Acceptance Criteria

- [ ] `Sources/FoundationModelsRouter/FoundationModelsRouter.swift` contains no string literal `"FoundationModelsRouter"`. A `grep -n '"FoundationModelsRouter"' Sources/FoundationModelsRouter/FoundationModelsRouter.swift` returns no match.
- [ ] `moduleName` still evaluates to `"FoundationModelsRouter"` at run time (the existing bootstrap assertion passes).
- [ ] `makeModuleLogger(category:)`, `RoutedLLM.swift:260` and `Router.swift:963` compile unchanged.
- [ ] `assertLogged(containing:since:)` in `Tests/FoundationModelsRouterTests/Helpers/LogAssertions.swift` still finds log entries under the `moduleName` subsystem — the suites that call it (`TranscriptEntryMapperTests`, `TranscriptReconstructionTests`, `GenerationStallDiagnosticTests`) stay green.

## Tests

- [ ] New test `moduleNameMatchesCompilerModule` in `Tests/FoundationModelsRouterTests/BootstrapTests.swift`: `#expect(moduleName == String(String(reflecting: Router.self).prefix { $0 != "." }))`.
- [ ] Run `swift build 2>&1` — expected: exit 0, zero warnings (do a clean build; a cache-hit build hides warnings).
- [ ] Run `swift test` — expected: all tests pass, `BootstrapTests` includes the new test. Do not use a display-name `--filter`; it matches nothing and exits 0.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.
#tech-debt #cleanup