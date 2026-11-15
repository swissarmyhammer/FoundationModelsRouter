---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m7ferfx931yq2y570hew31es
  text: |-
    ### commit — changed
    - evidence: fa16c40f chore: run Flint at the 4-bit flint-oQ4e (^tn74cyk); IntegrationTests build-tests green, compare.sh `bash -n` clean
    - next: run the StandardModel integration suites on oQ4e once the ACPAgent bench frees the GPU
  timestamp: 2026-11-15T11:16:27.177237+00:00
position_column: done
position_ordinal: ffffffffff9580
title: Switch the router's Flint references from flint-oQ8e to flint-oQ4e
---
User decision (via ACPAgent, 2026-11-15): use `mlx-community/flint-oQ4e` (rev 2310ad4e, 23.4 GB, 4-bit) in place of `flint-oQ8e`, "have router do that too". References: IntegrationTests StandardModels.flint, Benchmarks/compare.sh, Benchmarks/RouterBenchmark/README.md, and the doc comments in ReasoningControl.swift and StrayReasoningClose.swift. The stray-close evidence (SWE-bench run of 2026-11-14) was on oQ8e, and it stays recorded as such. No hermetic test names the model. The StandardModel integration suites are its test, and they wait until the GPU is free (the ACPAgent bench). #chore