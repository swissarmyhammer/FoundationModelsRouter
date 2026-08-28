---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14kjttg13v86wp8rq86r4z6
  text: |-
    Picked up and implemented with TDD.

    Research notes for the next agent:
    - `withSpan` in swift-distributed-tracing takes the parent from the task-local `ServiceContext.current`. `Router` is an actor, and an `await` on an actor method stays on the same Task, so the load span nests under the resolve span with no context passed by hand.
    - The load span sits in `acquireModel`, AFTER the `if var entry = pool[key] { ... return key }` early return. That is the one place where a pool hit is genuinely skipped, so a reused slot opens no span. Putting the span in `download(ref:slot:progress:load:)` would have been wrong: `download` is only reached on a fresh load, but the span then would not read as "one load per slot" if the call sites ever change.
    - `resolve(profile:reporting:)` now only opens the span and writes `router.id` + `profile.definition_name`; the old body moved to a private `runResolve(profile:reporting:span:)` which takes the span so it can write `budget.bytes` (the `effectiveBudget` local) and, on success, the chosen model for each slot.
    - The resolve span reports three slots at once, so one `model.ref` key cannot say which answer belongs to which slot. `RouterTracing.AttributeKey.chosenModelRef(slot:)` builds `model.ref.standard`, `model.ref.flash` and `model.ref.embedding` off the existing `modelRef` constant, so the vocabulary still has one home.
    - `ModelSlot` is not `CaseIterable`, so the test names its own `slotCount` constant rather than adding a conformance to production for a test.
    - Removed the `// periphery:ignore` markers for `SpanName.resolve`, `SpanName.load`, `AttributeKey.slot`, `AttributeKey.footprintBytes` and `AttributeKey.budgetBytes`. `SpanName.tool`, `SpanName.session` and `AttributeKey.toolName` keep theirs; the cards that use them have not landed.
    - `SpanContentSafetyTests` was not touched.
  timestamp: 2026-08-28T16:34:54.928813+00:00
- actor: claude-code
  id: 01m14kr00h88fx8s4hb2cd23c2
  text: |-
    Regression found and repaired during verification, recorded so the next agent does not repeat the diagnosis.

    `EmbedTracingTests` and `TurnTracingTests` both resolve their fixture profile through the SAME `InMemoryTracer` they then measure, and both counted the whole tracer (`tracer.finishedSpans.count == 1`). The new resolve span plus its three load spans broke that count: 6 tests failed.

    The repair is the pattern `ForkTracingTests` and `CompactionTracingTests` already use — filter the tracer by operation name. Nothing was weakened: each suite still requires exactly one span of its own name.
    - `TurnTracingTests.singleSpan(reportedTo:)` now filters on `spanName`.
    - `EmbedTracingTests` gained `finishedEmbedSpans(reportedTo:)`, and its three tests read through it. The third test used `tracer.finishedSpans.first`, which after this card would have read a LOAD span rather than the embed span, so it was measuring the wrong span even though it still passed.

    `SpanContentSafetyTests` needed no edit: it names no span, so it now measures the resolve and load spans too, which is what that suite was designed to do.
  timestamp: 2026-08-28T16:37:44.081281+00:00
- actor: claude-code
  id: 01m14kr6j4skyf014y377e6xgk
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Router.swift, Sources/FoundationModelsRouter/Tracing/RouterTracing.swift, Tests/FoundationModelsRouterTests/ResolveTracingTests.swift (new), Tests/FoundationModelsRouterTests/EmbedTracingTests.swift, Tests/FoundationModelsRouterTests/TurnTracingTests.swift. `swift build` complete. `swift test` 1096 tests in 114 suites passed with 2 known issues, plus 83 eval tests passed — baseline was 1090 in 113 suites, so the difference is the new 6-test `Resolve tracing` suite. `swift build --package-path IntegrationTests --build-tests` complete. TDD: the 6 new tests were watched failing (8 issues, no spans at all) before the instrumentation landed.
    - next: ready for /review
  timestamp: 2026-08-28T16:37:50.788633+00:00
- actor: claude-code
  id: 01m14m0t83ja5kff2m34d3s9hs
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 78a787c) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 5 files reviewed; 2 `.kanban` files excluded by `.reviewignore`. No prior Review Findings section. All acceptance criteria are marked.
    - checked three points by hand:
      1. The load span is below the pool early-return in `acquireModel` (Sources/FoundationModelsRouter/Router.swift). The `if var entry = pool[key]` block is the only pool-hit path and it returns first. A slot from the resident pool opens no load span.
      2. EmbedTracingTests and TurnTracingTests are not weakened. `TurnTracingTests.singleSpan` keeps `require(spans.count == 1)` under the name filter. Two EmbedTracingTests sites keep the same count assertion. The third site read `finishedSpans.first`, which had no count assertion before and has none now; the filter makes it read the embed span, not a load span.
      3. The per-slot key `chosenModelRef(slot:)` is correct. The resolve span reports all three slots at one time, and one `model.ref` key cannot hold three values and keep the slot of each. The card asks for the chosen `model.ref` for each slot.
    - the five `periphery:ignore` markers that were removed are the markers of the span names and attribute keys this card now writes. The markers that stay (`tool`, `session`, `toolName`) belong to other cards.
    - next: task moved to done.
  timestamp: 2026-08-28T16:42:33.091544+00:00
- actor: claude-code
  id: 01m14m1kd9492ebp5g0d44nyw9
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 5 files; Router.swift, RouterTracing.swift, new ResolveTracingTests.swift, EmbedTracingTests.swift, TurnTracingTests.swift
    - test: green — swift test, 1096 tests in 114 suites passed with 2 known issues, plus 83 eval tests. Baseline was 1090 in 113 suites, so the difference is exactly the new 6-test suite. `swift build --package-path IntegrationTests --build-tests` also completed.
    - commit: 78a787c
    - review: clean — review sha HEAD~1..HEAD, 0 findings, 7 validators attempted, 0 failed
    - next: none — the task is in done

    The reviewer confirmed the three points that needed proof, and not trust.

    The load span sits below the one pool-hit path in `acquireModel`, which returns before anything else runs. A slot served from the resident pool therefore opens no load span.

    The two existing suites were not weakened. Each still requires exactly one span of its own name; only the filter changed. One embed test had read `finishedSpans.first` with no count assertion, and after this change that call would have returned a load span, so the filter corrects it.

    The resolve span speaks for all three slots at once, so one `model.ref` key cannot carry three values and keep which slot each belongs to. A pool-hit slot has no load span, so the resolve span is the only place its winner can be named.

    Lesson for the tracing cards that remain: a suite that resolves its fixture through the tracer it measures must filter by operation name. A new span in any other part of the router will otherwise break it.
  timestamp: 2026-08-28T16:42:58.857847+00:00
depends_on:
- 01M12MM3EH1SBD3677NZGWMHD0
- 01M12MX0VV6WFY1RT4MCN40PVN
position_column: done
position_ordinal: ffff9a80
title: Open spans for profile resolution and model loads
---
## What

Wrap `Router.resolve` in one span, with one child span for each model load. Resolution is the slowest operation in the library; a trace must show where the time goes.

- Instrument `Router.resolve(profile:reporting:)` (Sources/FoundationModelsRouter/Router.swift:231).
- Outer span name: `FoundationModelsRouter.resolve` from `RouterTracing`. Kind: `.client`. Attributes: `router.id`, the profile definition name, `budget.bytes` (the `effectiveBudget` local at Router.swift:241), and, on success, the chosen `model.ref` for each slot.
- Child span name: `FoundationModelsRouter.load`, one for each slot the resolve loads through the `ModelLoader`. Attributes: `model.ref`, `slot` (`standard`, `flash`, or `embedding`), and `footprint.bytes`. A slot served from the resident pool opens no load span.
- Use the tracer helper from `RouterTracing`, which applies the `Router.tracer ?? InstrumentationSystem.tracer` rule.
- A resolve that throws (`ResolutionFailure`, or a loader error) must record the error on the outer span and throw again.
- Do not change the `ResolutionProgress` reporting; the spans are additional.

This task depends on the `HostProfileCache` removal, because that task changes `hostBudget()` — the computation behind the `budget.bytes` attribute recorded here.

## Acceptance Criteria
- [x] One successful resolve makes one resolve span and one load span for each loaded slot.
- [x] Each load span has the resolve span as its parent.
- [x] A resolve that fails keeps its span, with the error recorded.
- [x] A second resolve that reuses resident models opens no load span for the reused slots.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/ResolveTracingTests.swift`. Use `InMemoryTracer` with the stub loader fixtures from `ResolveTests.swift` and `Tests/FoundationModelsRouterTests/Helpers/HandBuiltProfileFixtures.swift`.
- [x] Assert the span names, the parent-child links, the attributes, the reuse case, and the error record.
- [x] Run `swift test`. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #tracing #router