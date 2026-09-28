---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3n0mchqa3he55spz0y3j6pc
  text: |-
    Research (implement, iteration 1):
    - Task ^rag2e91 (ebdaf8e, 7f747b8) did most of this work. `rg -n "FoundationModelsRouter\.tool"` outside `.build`, `.kanban` and `.git` finds nothing (exit 1).
    - `FoundationModelsExtras.tool` is in RoutedLLM.swift:249, Tracing/RouterTelemetry.swift:59 and ToolTracingTests.swift (the `toolSpanName` constant).
    - In Extras 6c399a4, the name is `ExtrasTelemetry.SpanName.tool` in `Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift`. `enum ExtrasTelemetry` and `enum SpanName` are internal, so the router test cannot read the name. The test keeps the string.
    - IntegrationTests/Package.resolved had Extras 70ad74d. The root has 6c399a4. All other pins were the same.

    Implementation:
    - ToolTracingTests.swift: the doc comment of `toolSpanName` now names the Extras file and the internal constant `ExtrasTelemetry.SpanName.tool`, and says why the test repeats the string.
    - IntegrationTests/Package.resolved (ignored by git): Extras revision set to 6c399a4b4703612ec6a2940c59c7d2b69b416670. It is now the same as the root file (diff is empty).
    - I stopped sourcekit-lsp pid 9296 (cwd is this repo). Then `swift build --build-tests --package-path IntegrationTests --manifest-cache local` passed: "Build complete!", exit 0. The only warning is the SwiftPM build-system message "missing creator for mutated node" for the mlx-swift_Cmlx.bundle. It is not a compiler warning.
  timestamp: 2026-09-28T22:02:11.895674+00:00
- actor: claude-code
  id: 01m3n0mmm18tz862sjf16vkjf8
  text: |-
    ### implement — changed
    - evidence: 1 tracked file — Tests/FoundationModelsRouterTests/ToolTracingTests.swift (doc comment names the Extras file). 1 ignored file — IntegrationTests/Package.resolved (Extras 6c399a4). IntegrationTests build passes.
    - next: /test
  timestamp: 2026-09-28T22:02:20.161613+00:00
- actor: claude-code
  id: 01m3n0t7b4y7c6dj61e6wndtc6
  text: |-
    ### test — green
    - evidence: swift test (one full run), exit 0 — 1400 tests in 177 suites passed (2 known issues, the same as in ^rag2e91), 22 tests in 10 suites passed, 19 tests in 3 suites passed. No compiler warning. The only warnings are from SwiftPM: the shared manifest cache "disk I/O error" and "missing creator for mutated node" for mlx-swift_Cmlx.bundle.
    - next: /commit
  timestamp: 2026-09-28T22:05:23.172790+00:00
position_column: doing
position_ordinal: '80'
title: 'OTel router E: use the Extras tool span name FoundationModelsExtras.tool in the router tests and docs'
---
## What
User decision (2026-09-28, relayed by the swissarmyhammer session): the tool span name changes from `FoundationModelsRouter.tool` to `FoundationModelsExtras.tool`. The tool span is opened by the Extras tool hosting (the router uses it since task ^nxke7g0), so the change is in Extras.

Blocked by Extras task 01M3MN9PAWGYCD0948TC91JNMP (^c91jnmp, Extras OTel D: the Extras telemetry vocabulary and the tool span rename). It must be on Extras `main`. Update the router's `Package.resolved` (ignored by git) with `swift package update FoundationModelsExtras`, and set `IntegrationTests/Package.resolved` to the same revision.

- `Tests/FoundationModelsRouterTests/ToolTracingTests.swift:31`: the test constant for the tool span name. If the Extras vocabulary is public, read the name from it and do not repeat the string.
- `Sources/FoundationModelsRouter/Tracing/RouterTracing.swift:40` (or `RouterTelemetry.swift`, if OTel router task A 01M3MND1G818WNMRPDFRAG2E91 is done first) and `Sources/FoundationModelsRouter/RoutedLLM.swift:250`: doc comments that name the tool span. Change them to the Extras name.
- Search the whole repo (Sources, Tests, IntegrationTests, docs, README, DocC) for `FoundationModelsRouter.tool` and change each reference.

Facts from the Extras OTel work (swissarmyhammer session, 2026-09-28; do not start until Extras OTel D is on Extras `origin/main`): the span name is `FoundationModelsExtras.tool`, and the names are in the Extras file `ExtrasTelemetry.swift`. `ToolCallSpan` is internal in Extras, and its `withSpan` body now gets a `ToolCallSpan.Call` value, not a raw span. If the name constant in `ExtrasTelemetry.swift` is not public, the test keeps the string and a comment names the Extras file.

## Acceptance Criteria
- [ ] No reference to `FoundationModelsRouter.tool` is left in the repo.
- [ ] The tool tracing tests check the span name `FoundationModelsExtras.tool`.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] `ToolTracingTests` passes with the new name.
- [ ] `swift test` passes one time, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #otel #cross-repo