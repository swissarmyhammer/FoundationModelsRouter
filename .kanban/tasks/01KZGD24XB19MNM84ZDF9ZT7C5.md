---
assignees:
- claude-code
position_column: todo
position_ordinal: '8380'
title: Gated ToolContext propagation probe records zero tool calls on the MLX path
---
Discovered by `^ce4hb6n`, which removed the `default.metallib` abort and so let this probe execute against real hardware for the FIRST time. Not a regression — never observable before.

Measured 2026-08-08, `FM_ROUTER_INTEGRATION_TESTS=1 swift test`, model `mlx-community/Qwen3.6-27B-mxfp4`:

`Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift:216` — test "MLX path: whether the ToolContext bound around respond() arrives inside call(arguments:)" fails on `#expect(observations.first)` after 47.6s. `observations` is empty, so `call(arguments:)` never ran at all.

## Why this matters, and why it is subtle

The probe is written to answer "does the `ToolContext` task-local survive `respond()`?" It cannot answer that question when the model never calls the tool: an empty `observations` array is indistinguishable from "the task local was lost" if you only read the assertion. The failure is therefore two problems at once:

1. **A probe-design gap.** The test conflates "no tool call happened" with "the context did not propagate". It needs to separate them — assert first that a tool call occurred, then assert what the context looked like inside it — so a future run reports which of the two failed.
2. **A likely instance of the zero-tool-call class.** A first assistant turn containing no tool calls is precisely the failure class card `^s4405wc` ("[Router] Pre-discovery seeding: deterministic first tool call via transcript construction") exists to make structurally impossible. That card records the measured finding that upfront prose cannot eliminate the class. If pre-discovery seeding lands, this probe may become deterministic for free.

Investigate whether this is the same class before designing a bespoke fix. Check the recorded transcript for the probe's turn to confirm the model produced prose instead of a tool call, rather than the tool being mis-mounted (a mounting bug would look identical from the assertion alone).

## Acceptance Criteria
- [ ] Determined and recorded which it is: model declined to call the tool, or the tool was never correctly mounted/visible
- [ ] The probe distinguishes "no tool call occurred" from "ToolContext did not propagate" — a failure names which happened
- [ ] The probe answers its actual question on real hardware: a tool call is observed, and the `ToolContext` assertion evaluates for real
- [ ] Relationship to `^s4405wc` recorded — either this is fixed by pre-discovery seeding (note the dependency) or it is independent (say why)
- [ ] Ungated `swift test` stays green

## Tests
- [ ] The gated run is the proof. Gated runs: one at a time, one shell command per run.
#phase-1