---
comments:
- actor: wballard
  id: 01m7dpr18t7sac7htyw61sj1a6
  text: |-
    ### implement — changed
    - ModelRef supports a revision in its string form, thus the default pins revision 61f8d8b7a8c2d84426d0d143ca187f65d235934b.
    - RED: the new test in DecisionSlotFitTests failed with notLogitsCapable, because the old default took the generic path. GREEN after the change.
    - evidence: Sources/FoundationModelsRouter/Core/ProfileDefinition.swift, Tests/FoundationModelsRouterTests/DecisionSlotFitTests.swift, README.md, docs/decision.md
    - swift test: 2700 tests in 314 suites passed; 42 tests in 23 suites passed; 19 tests in 3 suites passed. swift build --package-path IntegrationTests --build-tests: Build complete.
    - Not changed: Benchmarks/RouterBenchmark/README.md uses decider-4b as a GGUF example for --model, not as the default.
  timestamp: 2026-11-14T18:57:31.930780+00:00
position_column: done
position_ordinal: ffffffffff9080
title: Make h2o-lightning-4b the default decision model
---
## What
Make h2o-lightning-4b the default decision model of the Router, in place of decider-4b. Reason: in the FoundationModelsMetadataRegistry whole-catalog ranking benchmark (2026-11-14), h2o-lightning-4b had paraphrase hit@1 0.90 and multi-step hit@1 0.80; decider-4b had 1.00 and 0.60.

- ProfileDefinition.defaultDecisionCandidates becomes the h2o-lightning-4b GGUF: repo h2oai/h2o-lightning-4b-gguf, file h2o-lightning-4b-Q4_K_M.gguf. Pin revision 61f8d8b7a8c2d84426d0d143ca187f65d235934b if ModelRef and the profile JSON form allow a revision. Otherwise use the plain repo/file form.
- Update the doc comment: the file has the GGUF decision type h2o-lightning, so the decision slot takes the native decision path.
- One default. No alias for the old default.
- Update every test, fixture, example, README and doc that names decider-4b as the default.

## Acceptance Criteria
- [ ] defaultDecisionCandidates names the h2o-lightning-4b GGUF.
- [ ] A profile with no decision key resolves the decision slot to the native decision path.
- [ ] No source, test or doc names decider-4b as the default.
- [ ] swift test at the root passes.
- [ ] swift build --package-path IntegrationTests --build-tests passes.

## Tests
- [ ] Unit test: a profile with no decision key resolves the decision slot to the native decision path, with the GGUF header fixtures (no download).
- [ ] Update the tests that name decider-4b as the default.