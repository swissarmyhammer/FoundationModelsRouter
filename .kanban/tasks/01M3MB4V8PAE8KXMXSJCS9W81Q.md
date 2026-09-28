---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3mb82kvmj8q7nezh1gr9sg4
  text: |-
    Research (Extras at 4a733cd):
    - The `Operations` module declares 6 public typealiases to core Extras types: `ToolMount`, `ForkableTool`, `OperationEvent`, `OperationEventKind`, `OperationEventSink`, `OperationOutcome`. The router declares a typealias with each of these 6 names in `Hosting/OperationVocabulary.swift`. Thus all 6 names are ambiguous in a file that imports the router and `Operations`, not only `ToolMount`.
    - `Operations` does not declare `ToolMountError`. `ToolMountError` has no clash with `Operations`. The guard test uses it too.
    - `Marketplace` declares no public name that the router also declares. No other public router name clashes with an `Operations` public name.
    - Plan: replace the 6 router typealiases with scoped `@_exported import` of the original declarations (`struct ToolMount`, `protocol ForkableTool`, `struct OperationEvent`, `enum OperationEventKind`, `protocol OperationEventSink`, `enum OperationOutcome`).
    - No public-surface test uses `ToolMount` over a router-only import. I add one to the `FoundationModelsRouterPublicSurfaceTests` target, which depends only on the router.
  timestamp: 2026-09-28T15:48:28.411044+00:00
- actor: claude-code
  id: 01m3mbnzbp7nd23ff43q0dmb00
  text: |-
    Discovery (Swift 6.4, swiftlang-6.4.0.34.1): two typealiases with one name in two imported modules are NOT ambiguous when both point to the same type. Evidence:
    - `OperationsNameClashTests.swift` (router + `Operations` + Extras core, all 6 shared names unqualified) compiled on the current code.
    - `AgentOperationFixtures.swift` with `import FoundationModelsRouter` + `import Operations` and `@Operation(..., mount: ToolMount(mode: .background))` compiled on the current code. The same with `@testable import FoundationModelsRouter`.
    - A scratch package (Core struct, modules A and B each with `public typealias Mount = Core.Mount`, client imports A and B) compiled in debug and in release with library evolution.
    Thus the ambiguity of the card does not occur on this toolchain. The two tests stay as regression guards.

    A real defect of the typealias form: a file that imports only the router cannot name a nested type of `ToolMount` in a public declaration. Failing guard test on the current code (`swift build --build-tests`):
    ```
    Tests/FoundationModelsRouterPublicSurfaceTests/ToolMountPublicSurfaceTests.swift:64:32: error: cannot use enum 'Mode' in a property declaration marked public or in a '@frozen' or '@usableFromInline' context; 'FoundationModelsExtras' was not imported by this file
    ```
    The scratch package shows that `@_exported import struct Core.Mount` removes this error (debug and library evolution), keeps `A.Mount` as a qualified name, and gives no ambiguity beside a typealias in another module. I implement the card decision (scoped `@_exported import` for the 6 names that `Operations` also declares).
  timestamp: 2026-09-28T15:56:03.830623+00:00
- actor: claude-code
  id: 01m3mc16rww7j8phtn0nrsgz6a
  text: |-
    ### implement — changed
    - evidence: 4 files — Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift (6 typealiases `ToolMount`, `ForkableTool`, `OperationEvent`, `OperationEventKind`, `OperationEventSink`, `OperationOutcome` replaced by scoped `@_exported import` of the Extras declarations; `ToolMountError` stays a typealias because `Operations` does not declare it and it has no nested type), Tests/FoundationModelsRouterTests/OperationsNameClashTests.swift (new), Tests/FoundationModelsRouterTests/Helpers/AgentOperationFixtures.swift (now imports the router too), Tests/FoundationModelsRouterPublicSurfaceTests/ToolMountPublicSurfaceTests.swift (new; red before the change with the error in the comment above, green after).
    - checks: `swift build --build-tests` green; clean build with `--scratch-path <scratchpad>/clean` has 0 warnings and 0 errors in repo sources (examples included); `swift build --build-tests --package-path IntegrationTests` green.
    - next: test
  timestamp: 2026-09-28T16:02:11.868963+00:00
- actor: claude-code
  id: 01m3mc3jk04ffpn8e69vv6rdeh
  text: |-
    ### test — green
    - evidence: `swift test` (one full run) — FoundationModelsRouterTests 1360 tests in 171 suites passed (2 known issues are the intended `withKnownIssue` tests in BoundedWaitTests and RealModelHarnessTests); FoundationModelsRouterEvals 19 tests in 3 suites passed; FoundationModelsRouterPublicSurfaceTests 20 tests in 9 suites passed. 0 failures, 0 warnings in repo sources.
    - next: commit
  timestamp: 2026-09-28T16:03:29.504534+00:00
position_column: doing
position_ordinal: '80'
title: 'Router: ToolMount is not ambiguous in a file that imports both FoundationModelsRouter and Operations'
---
## What
Found in task 01M3HMSVSEHS10YD4PZ3RR9RN4 (^3rr9rn4): a file that imports both `FoundationModelsRouter` and the Extras `Operations` module sees two `ToolMount` names. `Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift:102` declares `public typealias ToolMount = FoundationModelsExtras.ToolMount`, and Extras `Sources/Operations/ToolMount.swift:8` declares the same typealias. Two typealiases with one name in two imported modules are ambiguous. FoundationModelsAgents imports both modules in `Sources/FoundationModelsAgents/Tool/AgentsToolOperations.swift` and `AgentsTool.swift`, and it must write `@Operation(..., mount: ToolMount(mode: .background))`. The test fixture `Tests/FoundationModelsRouterTests/Helpers/AgentOperationFixtures.swift` avoids the clash only because it imports only `Operations`.

A typealias beside the ORIGINAL type is not ambiguous (`ExtrasNameClashTests.swift` shows this for `FoundationModelsRouter` + `FoundationModelsExtras`).

Router decision (2026-09-28): the router re-exports the original type instead of a second typealias: replace the `ToolMount` typealias with `@_exported import struct FoundationModelsExtras.ToolMount`, and do the same for `ToolMountError` if it has the same problem. Router users keep writing `ToolMount` with only `import FoundationModelsRouter`. Check every other public router typealias to an Extras type that `Operations` (or another Extras product that router users import) also declares, and treat each one the same way. If a scoped `@_exported import` does not compile or does not remove the ambiguity, find a form that does and record it.

## Acceptance Criteria
- [ ] A file that imports `FoundationModelsRouter` and `Operations` can use `ToolMount(mode: .background)` and `ToolMountError` with no ambiguity.
- [ ] A file that imports only `FoundationModelsRouter` can still use `ToolMount` and `ToolMountError`.
- [ ] `ExtrasNameClashTests.swift` still compiles.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add a guard test file, for example `Tests/FoundationModelsRouterTests/OperationsNameClashTests.swift`, that imports `FoundationModelsRouter` and `Operations` (and `FoundationModelsExtras`) and uses `ToolMount` and every other shared public name. Change `Helpers/AgentOperationFixtures.swift` to import `FoundationModelsRouter` too, as a real user does.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #hosting #cross-repo #defect