---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14dav1qxn8924bt4yxrmqxf
  text: |-
    ### review — clean
    - scope: `review sha HEAD~1..HEAD` (commit 6f0b2a8), local backend. 4 files reviewed; the 2 `.kanban/` files are excluded by `.reviewignore`.
    - evidence: counts findings 0, confirmed 0, refuted 0; 7 validator runs attempted, 0 failed, 0 skipped.
    - criteria checked in the source, not from memory:
      - `enum ToolMounting` and both `static func makeWrapped` are internal (Hosting/ToolMounting.swift:4, 8, 29).
      - `protocol OperationEventSink` and its default extension are internal (Hosting/OperationEventSink.swift:4, 14, 16).
      - Both `ToolContext` initializers are internal (Hosting/ToolContext.swift:65, 104).
      - `SessionMailbox.makeCompletionToken()` and `SessionMailbox.init()` are internal (Hosting/SessionMailbox.swift:60, 121).
      - `public struct ToolContext` and `public actor SessionMailbox` stay public (Hosting/ToolContext.swift:10, Hosting/SessionMailbox.swift:15).
      - No public signature names the two demoted types. `public actor SessionOutbox: OperationEventSink` (Session/SessionOutbox.swift:24) is a conformance and not a signature; Swift keeps such a conformance internal, and a clean build proves no public signature exposes an internal type.
    - builds re-run for this review: `swift build` — Build complete; `swift build --package-path IntegrationTests --build-tests` — Build complete. The second build is the cross-package proof that `internal` is the correct level, because that package uses `@testable import`.
    - `swift test` result comes from the user's own run before the commit: 1072 tests in 110 suites passed with 2 known issues, plus 83 eval tests.
    - The implementing agent stopped on an LSP call and wrote no step record. The user made the commit. This review ticks the acceptance-criteria and test items after the checks above.
    - next: none. The task moves to `done`.
  timestamp: 2026-08-28T14:45:41.559046+00:00
- actor: claude-code
  id: 01m14dbsswhhrxvc1a3ghzvngz
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 4 source files (Hosting/ToolMounting.swift, Hosting/OperationEventSink.swift, Hosting/ToolContext.swift, Hosting/SessionMailbox.swift)
    - test: green — swift test, 1072 tests in 110 suites passed with 2 known issues, plus 83 eval tests. `swift build --package-path IntegrationTests --build-tests` also completed, which is the cross-package proof that `internal` is the correct level.
    - commit: 6f0b2a8
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - next: none — the task is in done

    Two notes for the record.

    The implementing agent stopped without a step record. It hung on an LSP diagnostics call, because sourcekit-lsp is not installed on this machine. Its work was complete; the state was verified again and committed by the orchestrator. Avoid `diagnostics check working` on this machine until a Swift language server is installed.

    The agent also found a defect from task ^zgwmhd0 while it worked. The tracer parameter has no default, and two tests in the nested `IntegrationTests` package construct a session actor directly, so that package did not build. A root `swift test` does not compile that package, so the review of ^zgwmhd0 could not see it. Commit 4561f2a repairs it. Every task that changes a shared initializer must run `swift build --package-path IntegrationTests --build-tests`.
  timestamp: 2026-08-28T14:46:13.052827+00:00
position_column: done
position_ordinal: ffff9580
title: Demote the mistakenly public Hosting plumbing to internal
---
## What

The audit found Hosting members that are public but have no consumer outside the module. All consumers are unit tests under `@testable import`, which crosses `internal`. Demote each to `internal`:

- `ToolMounting` and both `makeWrapped` (Sources/FoundationModelsRouter/Hosting/ToolMounting.swift:4, 8, 29).
- `OperationEventSink` and its default extension (Sources/FoundationModelsRouter/Hosting/OperationEventSink.swift:4, 16). Its one conformer is `SessionOutbox`.
- The two `ToolContext` initializers (Sources/FoundationModelsRouter/Hosting/ToolContext.swift:65, 104). The `ToolContext` type stays public; it is documented tool-authoring surface.
- `SessionMailbox.makeCompletionToken()` (Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:60) and `SessionMailbox.init()` (line 121). The actor stays public for now; a later task hoists its nested types and demotes it.

The DocC link repair that was in this task is now its own task, because four tasks touch that one catalog file.

## Acceptance Criteria
- [x] Each listed member is `internal`.
- [x] `ToolContext` and `SessionMailbox` types are still public.
- [x] No public signature in the module names `OperationEventSink` or `ToolMounting`.

## Tests
- [x] Run `swift build` and `swift test` at the root. All targets build and all tests pass; the plain-import support, example, and tool targets prove no demoted member was load-bearing.
- [x] Run `swift build --package-path IntegrationTests`. It builds; its `@testable import` still reaches the demoted members.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #cleanup

## Review Findings (2026-08-28 09:39)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

No findings.