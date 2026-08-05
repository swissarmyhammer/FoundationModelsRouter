---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7zdzmnz2ffe27v7dbzp0t1
  text: |-
    Research done. Verified all deletion sites: the only two `connecting(` call sites are RoutedLLM.instanceToolsWithElevation (root+restore chain) and RoutedSessionActor.fork's childTools map. Key discoveries:

    - ElevatingTool.call already binds ToolContext (sink = session outbox via RunEventFunnel) around every wrapped call — so the ambient event route is already live; deleting the connect step removes a redundant second route. RunEventFunnel semantics: a tool-posted `.completed` is forwarded upstream and suppresses the synthesized terminal (exactly one event lands in the outbox per posting call) — deterministic for outbox assertions after an in-band call.
    - EventEmittingToolTests.swift also holds OperationEvent Codable wire-shape tests (round trip, lowercase kind, `outcome` decodeIfPresent back-compat) that must survive — OperationEvent stays. Plan: move them to a new OperationEventTests.swift, delete the rest of the file.
    - Test rework strategy: replace sink-bound FakeEmittingTool/ForkableEmittingTool/EmittingStringTool fixtures with shared ambient-posting fixtures (post via ToolContext.current inside call) in Tests Helpers; composition assertions flip from "distinct sink-bound copy" to "original instance passes through, wrapped in the session's own ElevatingTool; calling the composed wrapper routes the event to that session's own outbox". Chain names: elevate → cap (root), fork → elevate → cap (fork), elevate (restore).
    - Extra stale prose beyond the card's list: "fork-then-connect"/"connect → elevate"/"sink-bound"/"auto-connect" phrases in RoutedLLM, RoutedSession, SessionTreeRestoration, LiveModelLoader (3 spots), plus plan.md's Hosting vocabulary line — all updated as part of the deletion.
    - TDD note: a pure protocol deletion cannot be forced red by a test (non-conforming tools already pass the cast unchanged, so the reworked identity assertions pass both before and after). Per dispatch instruction, deletion is verified by grep + green suite; the reworked tests pin the surviving contracts.
  timestamp: 2026-08-05T03:28:18.581436+00:00
- actor: claude-code
  id: 01kz800f0nptay619kw73vt6kk
  text: |-
    Implementation landed. Deleted Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift and both conformance-cast wiring sites (RoutedLLM.instanceToolsWithElevation, RoutedSessionActor.fork childTools map); updated all doc prose (chains renamed elevate → cap / fork → elevate → cap / elevate; "fork-then-connect" → "fork-then-elevate"; "sink-bound"/"auto-connect" wording removed) across RoutedLLM, RoutedSession, SessionTreeRestoration, ForkableTool, OperationEventSink, SessionOutbox, ToolOutputCapping, LanguageModelSessionBackend, LiveModelLoader, PropagationProbeIntegrationTests, plan.md.

    Tests: EventEmittingToolTests.swift deleted; its OperationEvent Codable wire-shape tests preserved in new OperationEventTests.swift. New shared fixtures Helpers/AmbientEventToolFixtures.swift (AmbientEventPostingTool, ForkableAmbientTool — post via ToolContext.current). SessionOutboxToolWiringTests + SessionTreeRestorationToolWiringTests + ToolOutputCappingTests reworked: composition assertions now pin "original instance passes through inside the session's own ElevatingTool; calling the composed wrapper routes the event to that session's own outbox" (parent/fork isolation, restore per-node isolation, cap-outermost all still behaviorally verified through the ambient route).

    Verification: grep for `EventEmittingTool|connecting(` over the whole repo returns nothing; `swift test` green — 720 tests (unit) + 20 (integration target, gated suites compile+skip) + 12 (evals), zero failures; only warning is the pre-existing SwiftPM mlx-bundle note.
  timestamp: 2026-08-05T03:38:24.149150+00:00
- actor: claude-code
  id: 01kz80vzzbsdcn3d6x8zbcpvbz
  text: |-
    Correction to the previous verification comment (double-check Finding 2): the grep claim was overstated. Verified scope: grep for `EventEmittingTool|connecting(` over `Sources/` and `Tests/` returns nothing — the task's acceptance criterion. Remaining repo-wide hits are confined to the vendored `FoundationModelsOperationTool` checkout under `.build/`, which still defines the protocol but is not a dependency of this package (Package.swift lists only mlx-swift-lm/ULID/HuggingFace/Transformers, and nothing imports it).

    Double-check Finding 1 addressed: the rewritten doc prose claimed "every tool" is wrapped in the elevation layer, but `ToolElevation.wrapping`/`ToolOutputCapping.wrapping` only wrap String-output tools — reworded all five sites (RoutedLLM makeSession tools: param + instancing comment + instanceToolsWithElevation doc, RoutedSession.tools doc, SessionTreeRestoration tools: param, ForkableTool composition-order doc) to state the String-output condition and the turn-scope ToolContext fallback for non-String-output tools. The pre-existing identity/correlation gap that fallback creates (per-tool `tool`/`op`/`correlationID` stamps lost for non-String-output tools, no test coverage) is filed as a follow-up task on this board.
  timestamp: 2026-08-05T03:53:26.251435+00:00
- actor: claude-code
  id: 01kz81g24bgwf059yyx0sqxmwn
  text: |-
    ### implement — changed
    - evidence: deleted Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift + Tests/FoundationModelsRouterTests/EventEmittingToolTests.swift; edited Sources/FoundationModelsRouter/RoutedLLM.swift, Session/RoutedSession.swift, Session/SessionOutbox.swift, Session/ToolOutputCapping.swift, Session/LanguageModelSessionBackend.swift, Recording/SessionTreeRestoration.swift, Hosting/ForkableTool.swift, Hosting/OperationEventSink.swift, Resolution/LiveModelLoader.swift, Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift, SessionTreeRestorationToolWiringTests.swift, ToolOutputCappingTests.swift, Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift, plan.md; added Tests/FoundationModelsRouterTests/OperationEventTests.swift + Helpers/AmbientEventToolFixtures.swift. Verified: grep `EventEmittingTool|connecting(` over Sources/+Tests/ → 0 hits; `swift test` → 720+20+12 tests passed, 0 failures; `review working` → 0 findings (twice); double-check findings implemented (String-output prose correction, follow-up task ^6htgvw2 filed, grep-scope comment corrected).
    - next: ready for /review
  timestamp: 2026-08-05T04:04:23.819167+00:00
- actor: claude-code
  id: 01kz82bjjsdhepj3hxejy53yyk
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (commit e1b62fa) — 1 confirmed finding: Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:307 (outbox/mailbox + tool-instancing block duplicated with RoutedLLM.swift:201; extract shared helper parameterized by sessionID and tokenLimit)
    - next: /implement ^ew49xjj to resolve the checklist item, then re-review
  timestamp: 2026-08-05T04:19:25.401106+00:00
- actor: claude-code
  id: 01kz82fbh91zbbey50j40redwe
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 2 deleted (EventEmittingTool.swift, EventEmittingToolTests.swift), 2 added (OperationEventTests.swift, AmbientEventToolFixtures.swift), 14 edited; grep clean; follow-up ^6htgvw2 filed
    - test: green — swift test, 752 passed, 0 failures, 32 expected gated skips
    - commit: e1b62fa
    - review: findings — 1: Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:307 duplicated with Sources/FoundationModelsRouter/RoutedLLM.swift:201 (extract shared helper parameterized by sessionID and tokenLimit)
  timestamp: 2026-08-05T04:21:29.257891+00:00
- actor: claude-code
  id: 01kz83q1wgmsft3eyy2s461168
  text: |-
    Picked the card back up from review to work the single review finding (SessionTreeRestoration.swift:307 duplicated with RoutedLLM.swift:201).

    Fix: folded the outbox/mailbox minting into the existing shared helper — `instanceToolsWithElevation(_:sessionID:outbox:mailbox:cappedToTokenLimit:)` became `RoutedModel.makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)`, which now mints the fresh SessionOutbox/SessionMailbox itself and returns `(outbox, mailbox, tools)`. Both former duplication sites (makeSession root site, restoreSessionTree restore site) now make one call; grep confirms `instanceToolsWithElevation` is gone repo-wide. Doc references updated in RoutedLLM.swift, RoutedSession.swift, SessionTreeRestoration.swift.

    Self-review surfaced two more findings, both fixed:
    1. The per-tool elevate+cap chain was still duplicated between makeSessionToolWiring and RoutedSessionActor.fork's childTools map — extracted `ToolElevation.sessionMounted(_:sessionID:mailbox:sink:cappedToTokenLimit:)` (in Session/ToolOutputCapping.swift, keeping the public Hosting file free of the Session-side capping dependency); both sites use it, fork still forks first and mints its own child wiring (fork → elevate → cap unchanged). Also removed stale "connected copy" wording in fork's comment.
    2. Doc-parameter names not matching external argument labels — swept both flagged files (RoutedLLM.swift: cappedToTokenLimit, forSessionId, resuming; ToolOutputCapping.swift: toTokenLimit x3, of/keepingAtMostUTF8Bytes, cappedToTokenLimit).

    Behavior unchanged by construction (same instances, same order, same cap limits per site: root budget?.toolOutputLimit, restore nil, fork autoCompactionBudget?.toolOutputLimit). swift build clean; swift test green (720+20+12, 0 failures); `review working` now returns 0 findings. TDD note: pure extract-refactor with identical behavior — existing wiring tests are the safety net per the dispatch instruction; no test can be written that fails before and passes after.
  timestamp: 2026-08-05T04:43:10.096041+00:00
- actor: claude-code
  id: 01kz852j1t5fq5abwbsjq5cxd8
  text: |-
    Double-check returned REVISE with 4 findings; all implemented:

    1. Doc prose now agrees with the renamed `- Parameters:` entries in RoutedLLM.swift and Session/ToolOutputCapping.swift — every backticked internal-name reference in those doc comments was renamed to the external label (`toTokenLimit`, `cappedToTokenLimit`, `keepingAtMostUTF8Bytes`, `forSessionId`) or rephrased to plain English where the label reads badly (`makeLanguageModel(resuming:)` prose says "the resumed session's"; `prefix` prose says "the given text").
    2. Label-vs-internal doc-naming convention split: measured repo-wide — 91 doc-parameter entries across ~20 files still use the internal name where an external label exists. The engine's swift validator enforces the label form on changed files (three concrete findings this session), so the label direction is the enforced one; the sweep is a mechanical repo-wide doc refactor out of this card's scope and is filed as task ^6e4d1pn (records the measurement, the pattern to apply, and acceptance criteria). Not resolved silently: recorded here and on that card.
    3. Open task ^6htgvw2's acceptance criterion no longer names the deleted `instanceToolsWithElevation` — it now names `RoutedModel.makeSessionToolWiring(_:sessionID:cappedToTokenLimit:)` and `ToolElevation.sessionMounted(...)`, with a note about the rename.
    4. `ToolElevation`'s enum doc in Hosting/ElevatingTool.swift now cross-references `sessionMounted(...)` and states why it lives in Session/ToolOutputCapping.swift (keeps the Hosting file free of the capping dependency).

    The follow-up `review working` was incomplete once (9/18 tasks failed) and produced 2 new findings on ToolOutputCapping.swift: first parameter label omitted on `wrapping` and `optionallyCapped` (rule permits omission only for value-preserving conversions). Implemented file-wide per the same cause: `capped(text:toTokenLimit:)`, `wrapping(tool:toTokenLimit:)`, `optionallyCapped(tool:toTokenLimit:)`, `sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)` — all call sites (incl. RoutedLLM/RoutedSession composition sites and ToolOutputCappingTests) and every doc/signature reference updated. `ToolElevation.wrapping(_:sessionID:...)` in Hosting/ElevatingTool.swift was left as is: different file, public API, not flagged.

    Verification: swift build clean; swift test 720+20+12, 0 failures; `review working` now 18/18 attempted, 0 failed, 0 findings.
  timestamp: 2026-08-05T05:06:55.674928+00:00
- actor: claude-code
  id: 01kz852t0rcmtc1m8k3gfgfqg0
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/RoutedLLM.swift (instanceToolsWithElevation folded into makeSessionToolWiring minting outbox/mailbox; doc-label + prose fixes), Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift (restore site uses the shared helper), Sources/FoundationModelsRouter/Session/RoutedSession.swift (fork uses shared per-tool ToolElevation.sessionMounted), Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift (sessionMounted added; first-parameter labels capped(text:)/wrapping(tool:)/optionallyCapped(tool:)/sessionMounted(tool:); doc fixes), Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift (ToolElevation doc cross-reference), Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift (renamed call sites/signature strings). Review-finding checklist item flipped to [x]; follow-up tasks ^6e4d1pn filed and ^6htgvw2 updated. swift build clean; swift test 720+20+12 passed, 0 failures; review working 18/18, 0 findings; double-check REVISE feedback fully implemented.
    - next: ready for /review
  timestamp: 2026-08-05T05:07:03.832337+00:00
- actor: claude-code
  id: 01kz858kckrskwswe3xr3r2c46
  text: |-
    ### test — green
    - evidence: `swift test` (full ungated run, no FM_ROUTER_INTEGRATION_TESTS) — exit 0; 720 tests/69 suites passed, 20 tests/8 suites (24 gated skips), 12 tests/4 suites (4 gated skips); 0 failures, 0 unexpected warnings (only the known pre-existing "missing creator for mutated node" llbuild warning from the mlx-swift Cmlx bundle)
    - next: proceed to review
  timestamp: 2026-08-05T05:10:13.651687+00:00
position_column: doing
position_ordinal: '80'
title: '[Router] Delete EventEmittingTool/connecting(_:) and the conformance-cast wiring (propagation probe verdict: context propagates)'
---
Repo: this repo (FoundationModelsRouter). Basis: task ^c25mpnw's propagation probe verdict (PropagationProbeIntegrationTests, real run 2026-08-04): the @TaskLocal ToolContext bound around respond() DOES arrive inside call(arguments:) on both the MLX path and the system model, carrying the exact bound completionToken. Per eventplan.md §"Phases" phase 1 and §"The ambient context" effect 3, the propagates-branch deletes the protocol: native tools get the ambient context free, so composition-time event wiring is redundant.

## What
Delete the `EventEmittingTool` protocol and every conformance-cast wiring site, leaving the ambient `ToolContext` (bound per call by `ElevatingTool`, and by `RoutedSessionActor` around backend calls) as the one event route.

Code deletion sites (verified by grep — the only two `connecting(` call sites in Sources/):
- `Sources/FoundationModelsRouter/Hosting/EventEmittingTool.swift` — the whole file.
- `Sources/FoundationModelsRouter/RoutedLLM.swift` — the `(tool as? any EventEmittingTool)?.connecting(outbox) ?? tool` step in the per-session tool composition (and the doc comments describing "implementing the protocol IS the subscription").
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift` — the fork path's `(forked as? any EventEmittingTool)?.connecting(childOutbox) ?? forked` step and the `connecting(_:)`-centric doc comments on `tools`/fork composition.

Doc-comment-only references to update (no `connecting(` call sites; prose only):
- `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift` (restoration goes through the shared `instanceToolsWithElevation` helper; its doc comments describe the per-node `connecting(_:)` copy)
- `Sources/FoundationModelsRouter/Hosting/ForkableTool.swift` (composition-order contract)
- `Sources/FoundationModelsRouter/Hosting/OperationEventSink.swift`
- `Sources/FoundationModelsRouter/Session/SessionOutbox.swift`
- `Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift`
- `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`
- `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`

Tests to delete/rework (every test file declaring an `EventEmittingTool` conformance or composing through `connecting(_:)`):
- `Tests/FoundationModelsRouterTests/EventEmittingToolTests.swift` — delete/rework wholesale.
- `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift` — its `FakeEmittingTool` conformance and the composition-order suites built on it.
- `Tests/FoundationModelsRouterTests/SessionTreeRestorationToolWiringTests.swift` — its emitting-tool conformance.
- `Tests/FoundationModelsRouterTests/ToolOutputCappingTests.swift` — `cappingComposesWithEventEmittingTool` and any other `connecting(_:)` composition.
- Sweep the remaining `EventEmittingTool` grep hits in Tests/ after these — the protocol must not survive anywhere.

Keep `OperationEventSink` and `SessionOutbox`'s sink conformance — the ambient `ToolContext` still posts through a sink; only the tool-side discovery protocol and its cast wiring go away.

## Acceptance Criteria
- [ ] `EventEmittingTool` and `connecting(_:)` no longer exist anywhere in Sources/ or Tests/
- [ ] Session/fork/restoration tool composition still wires elevation (`ToolElevation.wrapping`) and capping, with events flowing through the ambient `ToolContext` only
- [ ] `swift test` (ungated) green; gated suites still compile

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-08-04 23:08)

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:307` — The outbox/mailbox creation and tool instancing pattern is duplicated in RoutedLLM.swift:201. Two nearly-identical blocks differ only by sessionID parameter and cappedToTokenLimit value — extract into a shared helper function. Extract a new helper function in RoutedLLM (or RoutedModel if accessible from both) to consolidate the outbox/mailbox/tool-instancing setup, parameterized by sessionID and tokenLimit. #phase-1 #router-first