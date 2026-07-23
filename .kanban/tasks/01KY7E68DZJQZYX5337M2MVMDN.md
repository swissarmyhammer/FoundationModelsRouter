---
position_column: todo
position_ordinal: '9880'
title: 'Fold the harness plan into Router: docs + the constructor-fed guardrail'
---
The collapse decision (2026-07-23): FoundationModelsAgentHarness's residue moves here; Router is the family's runtime. Absorb into plan.md/compaction_plan.md/DocC: the loop semantics (harness plan §4 — turn serialization, no queueing, cancel), §5 policy (auto-fold + retry), §5.1 mid-turn strategy, §5.2 root-vs-sub-agent (one session surface, constructor values are the role), §9 testing items (sample tools: echo/failing/document-generator as test-only fixtures). Write the GUARDRAIL as a guiding principle: Router's session surface is constructor-fed — it never names a tool package, never reads a config file, never speaks a wire protocol; tools/instructions/budget arrive as values (composition lives in FoundationModelsACPAgent). Do NOT retire the harness repo yet (active session rooted there); its plan gets a collapsed-into-Router banner in a later pass.