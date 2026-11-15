---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: Switch the router's Flint references from flint-oQ8e to flint-oQ4e
---
User decision (via ACPAgent, 2026-11-15): use `mlx-community/flint-oQ4e` (rev 2310ad4e, 23.4 GB, 4-bit) in place of `flint-oQ8e`, "have router do that too". References: IntegrationTests StandardModels.flint, Benchmarks/compare.sh, Benchmarks/RouterBenchmark/README.md, and the doc comments in ReasoningControl.swift and StrayReasoningClose.swift. The stray-close evidence (SWE-bench run of 2026-11-14) was on oQ8e, and it stays recorded as such. No hermetic test names the model. The StandardModel integration suites are its test, and they wait until the GPU is free (the ACPAgent bench). #chore