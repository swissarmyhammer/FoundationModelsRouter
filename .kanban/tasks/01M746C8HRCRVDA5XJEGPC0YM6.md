---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m76f1p950mth7wxavsn7xrhw
  text: |-
    Research (implement step). Facts checked in the code:
    - Span name `FoundationModelsRouter.decide` (Tracing/RouterTelemetry.swift, SpanName.decide), kind client, attributes `router.id`, `model.ref`, `decision.question_count`. A prewarm opens no span.
    - `ReasoningOffPromptFormat` is gone. FoundationModelsDecision is pinned at 48d53e9 in Package.resolved: `GenericPromptFormat` with `closedThinkFallback: false` throws `DecisionError.unsupportedModel` for an open thinking block.
    - Format rule: `DecisionFormatSelection` + `DecisionFormatLoader` read `decider_config.json` at the repository root through the MetadataSource. If the read fails, `DecisionSlotPlan` changes the slot to the flash fallback and logs a warning on the `FoundationModelsRouter.RepoMetadataReader` logger.
    - `JointFit.resolveDecision` runs after the trio, at the trio context, with the budget the trio left. A candidate that a pool key of a trio winner serves costs 0 bytes.
    - `SlotResolution` / `CandidateReport` / `Verdict` are `package` or internal, so an app cannot read the decision rejections. Public signs of the fallback: `profile.decision.chosen == profile.flash.chosen`, `footprintBytes == 0`, `ResolutionProgress.slots[.decision]?.chosen`, resolve span attribute `model.ref.decision`.
    - The DocC catalog has no root topics page and no page that names `RoutedEmbedder`. I will add a root page `FoundationModelsRouter.md` with a "Model handles" topic group.
    - docs/residency.md says "three model holds"; there are four holds now (one for each slot).
    - Integration test: IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/DecisionSlotIntegrationTests.swift (decider-2b Q4_K_M at revision 0df001b, flash Qwen3.5-0.8B GGUF).
    - A consumer imports `FoundationModelsDecision` for `DecisionState` and `DecisionSession` (Package.swift comment). The router does not re-export them.
    - ExamplesTests resolves through a stub loader whose LLM container gives no logits, so `profile.decision` of a resolve throws `notLogitsCapable`. The decision examples use a hand-built profile (HandBuiltProfileFixtures + StubDecisionContainer).
  timestamp: 2026-11-11T23:28:18.725763+00:00
- actor: claude-code
  id: 01m76fb3xb8pwy9fv80tbkv58z
  text: |-
    Implementation done.
    - TDD: the two new ExamplesTests failed first with "cannot find 'DecideTool' in scope", then passed after DecideTool was added.
    - The README decision example is copied into ExamplesTests "Ask the decision model for the probability of yes to a question about a state". It uses a hand-built profile (ExampleHarness.makeDecisionProfile), because a stub-loader resolve gives a decider that throws notLogitsCapable.
    - DocC: the catalog had no root topics page. I added FoundationModelsRouter.docc/FoundationModelsRouter.md with the topic groups Profiles, Model handles (RoutedLLM, RoutedEmbedder, RoutedDecider), Loaded containers (includes LoadedDecisionContainer) and Sessions. I could not build the DocC locally: swift-symbolgraph-extract cannot load the module (C++ interop and missing shim modules). I checked each symbol that the page names against the `public` declarations.
    - docs/decision.md: the rejections in the resolution are `package` API (`profile.decision.resolution`). The doc says this and also gives the public signs of the fallback.

    ### implement — changed
    - evidence: README.md, docs/decision.md (new), docs/residency.md, docs/testing.md, Sources/FoundationModelsRouter/Tools.swift, Sources/FoundationModelsRouter/FoundationModelsRouter.docc/FoundationModelsRouter.md (new), Tests/FoundationModelsRouterTests/ExamplesTests.swift; `swift test` one time: 2638 tests in 305 suites + 41 + 19 passed, exit 0, no warnings
    - next: /review
  timestamp: 2026-11-11T23:33:27.595393+00:00
- actor: claude-code
  id: 01m76ffpxc12pmnmsw5e4tdg28
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (dd400003); 1 finding (1 confirmed, 0 refuted) — Sources/FoundationModelsRouter/Tools.swift:77
    - next: implement the unchecked item in the "Review Findings (2026-11-11 18:35)" section. Remove the explicit initializer that is identical to the synthesized initializer, and remove each other example of this cause in Tools.swift.
  timestamp: 2026-11-11T23:35:58.124687+00:00
- actor: claude-code
  id: 01m76fg33zdjr93d5m07dg4s3h
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — README.md, docs/decision.md (new), docs/residency.md, docs/testing.md, Tools.swift (DecideTool), FoundationModelsRouter.docc/FoundationModelsRouter.md (new), ExamplesTests.swift
    - test: green — swift test, 2638 + 41 + 19 passed, 0 skipped
    - commit: dd400003
    - review: findings — Sources/FoundationModelsRouter/Tools.swift:77
  timestamp: 2026-11-11T23:36:10.623149+00:00
- actor: claude-code
  id: 01m76fk0gyx96s4h4zg4rddnaa
  text: |-
    Fix for the UseSynthesizedInitializer finding.
    - I removed the explicit `init(model:)` from `DecideTool`. The synthesized memberwise initializer is internal and has the same signature, so `DecideTool(model: profile.decision)` in ExamplesTests did not change.
    - The type DocC now tells how to create the tool: the memberwise initializer `DecideTool(model:)` with a resolved `RoutedDecider`. The `model` property doc tells that the tool decides through it.
    - I examined the other lines that dd400003 added. The new test code (`makeDecisionProfile`, `decideAboutAState`, `decideThroughATool`) has no explicit initializer. I did not change the older tools (`SummarizeTool`, `EmbedTool`).

    ### implement — changed
    - evidence: Sources/FoundationModelsRouter/Tools.swift; `swift test` one time: 2638 tests in 305 suites + 41 + 19 passed, exit 0, no compiler warnings
    - next: /review
  timestamp: 2026-11-11T23:37:46.270700+00:00
- actor: claude-code
  id: 01m76fnxjz223hqtpccbx37zbe
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (890da904): 0 findings, 0 confirmed, 0 refuted; 7 attempted, 0 failed. All prior findings are checked.
    - next: none. The task moved to done.
  timestamp: 2026-11-11T23:39:21.567422+00:00
- actor: claude-code
  id: 01m76fpd5f596qabamvcnbc4tw
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — Sources/FoundationModelsRouter/Tools.swift (DecideTool synthesized init)
    - test: green — swift test, 2638 + 41 + 19 passed, 0 skipped
    - commit: 890da904
    - review: clean — 0 findings
  timestamp: 2026-11-11T23:39:37.519081+00:00
depends_on:
- 01M746AWW5JWZK2017CJMC5VMJ
- 01M746B9WYHASZZGR6P8SC4C1K
- 01M746BHT4HMJY6R5ZFA9DKCBK
position_column: done
position_ordinal: ffffffffff8580
title: 'R11: document the decision slot (README, docs/decision.md, DocC)'
---
## What
Source: ../FoundationModelsDecision/plan.md section 7, R11. Write all text in ASD-STE100 Simplified Technical English.

- `README.md`: add `decision` to the profile example, and a short example of `profile.decision.makeSession(state: .text(ticket)).probability(of: "Does this convey urgency?")`.
- New `docs/decision.md`: the slot (`ModelSlot.decision`, pool role `.llm`); the default candidate `Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf`; the prompt-format rule (a repository with `decider_config.json` → `DeciderPromptFormat`; no such file → `GenericPromptFormat`); the memory rule (only the memory left after embedding, standard and flash; a candidate equal to an allocated model costs 0 bytes); the flash fallback and how to read the rejections in the resolution; no transcript entry; the `decide` span and its three attributes; the integration test model `decider-2b`.
- DocC catalog `Sources/FoundationModelsRouter/FoundationModelsRouter.docc`: add `RoutedDecider` and `LoadedDecisionContainer` to the topics page next to `RoutedEmbedder`.
- `docs/residency.md`: one line for the decision slot, if it lists the slots.

## Acceptance Criteria
- [x] `README.md`, `docs/decision.md` and the DocC topics name the decision slot, and each symbol that they name exists in the code.
- [x] The README example compiles: copy it into a test.

## Tests
- [x] Add the README example to `Tests/FoundationModelsRouterTests/ExamplesTests.swift` with a stub decider, so that the example compiles and runs.
- [x] Run `swift test` once. All tests pass.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #decision
## Changes from the board check
- `Sources/FoundationModelsRouter/Tools.swift` says "Pass `profile.flash`, `profile.standard`, or `profile.embedding` in". Add `profile.decision`, and add a `DecideTool` example next to `EmbedTool` (a tool that takes a `RoutedDecider` and answers one yes/no question). Add a test for it in `Tests/FoundationModelsRouterTests/ExamplesTests.swift` with the stub decider.


## Review Findings (2026-11-11 18:35)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 2 file(s) reviewed, 9 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 5 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/FoundationModelsRouter.md` — no validator matches this file
> - `docs/decision.md` — no validator matches this file
> - `docs/residency.md` — no validator matches this file
> - `docs/testing.md` — no validator matches this file

- [x] `Sources/FoundationModelsRouter/Tools.swift:77` `code-hygiene/idioms-swift` — UseSynthesizedInitializer: remove this explicit initializer, which is identical to the compiler-synthesized initializer.
