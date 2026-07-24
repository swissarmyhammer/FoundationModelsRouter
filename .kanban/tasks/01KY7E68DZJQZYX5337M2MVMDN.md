---
comments:
- actor: claude-code
  id: 01kyam39y8gccs6j19j1sg16wn
  text: |-
    Research: found the harness plan at ../FoundationModelsAgentHarness/plan.md (sibling repo). Checked all sibling kanban tasks tagged "harness plan §" — every implementation item (§7 tools threading, derived context, session creation metadata, §5/§5.1 auto-compaction + mid-turn guards, §4 rich event stream, §5.2/§10 @Observable projection) is already done and merged, each with its own doc-comment cross-references to "harness plan §X" already sprinkled through Sources/. This task is purely the higher-level narrative: fold the guiding principles into plan.md/compaction_plan.md and state the constructor-fed guardrail explicitly (no DocC catalog exists in this package — docs live as source doc comments + these two plan files).

    Implemented (docs only, no production code changed):
    - plan.md: new "## Guiding principle: constructor-fed, zero configuration (the guardrail)" section (after Goal) + "### The collapse (2026-07-23): FoundationModelsAgentHarness folds in" subsection mapping each harness-plan section to where it landed.
    - plan.md: new "## Turn loop: serialization, queueing, and cancellation (harness plan §4 absorbed)" and "## Root and sub-agent: one session surface (harness plan §5.2 absorbed)" sections (after Concurrency, before Sessions: working directory & isolation).
    - plan.md: new Decisions bullet recording the collapse; new Testing paragraph documenting the sample-tools-only convention (harness plan §9 absorbed).
    - compaction_plan.md: new "### 1.6 Loop policy: the auto-compaction opt-in (harness plan §5 absorbed)" and "### 1.7 Mid-turn strategy: the two in-loop seams (harness plan §5.1 absorbed)" sections; updated two stale "(the agent harness, the ACP bridge)" mentions for accuracy now that the harness's loop runs directly over RoutedSession; new Decisions (§7) bullet.
    - FoundationModelsAgentHarness repo itself untouched, per the task's explicit instruction (not retired yet, active session rooted there) and per house rule against cross-repo kanban work.

    Verification: swift build clean (0 warnings beyond the known pre-existing mlx-swift_Cmlx.bundle warning); swift test: 546 unit + 18 gated + 5 evals = 569/569 passing, matching the stated baseline exactly (docs-only change, no test count drift). Adversarial double-check spawned to verify every technical claim in the new prose against actual current source (API names, signatures, behavior) before handoff.
  timestamp: 2026-07-24T17:52:15.816473+00:00
- actor: claude-code
  id: 01kyama5f2k94xae3p923xezmn
  text: |-
    Adversarial double-check round 1: REVISE — found a fabricated claim in plan.md's guardrail section that Package.swift depends on `swift-argument-parser` (it does not), plus imprecise "no tool package" wording that glossed over the real `FoundationModelsOperationTool` (Operations product) dependency.

    Fixed: rewrote the guardrail section's dependency description to match Package.swift exactly (mlx-swift-lm fork + MLX products, swift-huggingface/swift-transformers for gated integration, ULID.swift, FoundationModelsOperationTool's Operations product — a host-neutral tool-events vocabulary, not a tool catalog). Changed "tool package" to "tool catalog" throughout both the guardrail section and the "Sample tools only" Testing paragraph, with an explicit files/shell/MCP clarification, since Operations genuinely is a dependency but never implements a concrete tool.

    Adversarial double-check round 2 (targeted re-check of just these two fixes): PASS. Confirmed no swift-argument-parser claim remains, confirmed the dependency list matches Package.swift's five `.package(...)` entries exactly, and confirmed via grep that every `EventEmittingTool` conformance in Sources/ is a protocol-conformance check, never a concrete implementation (only test-only fakes conform).

    Final verification: swift build clean (0 warnings beyond the known pre-existing mlx-swift_Cmlx.bundle warning); swift test: 546 unit + 18 gated + 5 evals = 569/569 passing (docs-only change, baseline unchanged). Diff: plan.md +137/-6, compaction_plan.md +89/-7, both markdown-only.

    Task is green and left in `doing`, ready for `/review`.
  timestamp: 2026-07-24T17:56:00.610355+00:00
position_column: done
position_ordinal: de80
title: 'Fold the harness plan into Router: docs + the constructor-fed guardrail'
---
The collapse decision (2026-07-23): FoundationModelsAgentHarness's residue moves here; Router is the family's runtime. Absorb into plan.md/compaction_plan.md/DocC: the loop semantics (harness plan §4 — turn serialization, no queueing, cancel), §5 policy (auto-fold + retry), §5.1 mid-turn strategy, §5.2 root-vs-sub-agent (one session surface, constructor values are the role), §9 testing items (sample tools: echo/failing/document-generator as test-only fixtures). Write the GUARDRAIL as a guiding principle: Router's session surface is constructor-fed — it never names a tool package, never reads a config file, never speaks a wire protocol; tools/instructions/budget arrive as values (composition lives in FoundationModelsACPAgent). Do NOT retire the harness repo yet (active session rooted there); its plan gets a collapsed-into-Router banner in a later pass.