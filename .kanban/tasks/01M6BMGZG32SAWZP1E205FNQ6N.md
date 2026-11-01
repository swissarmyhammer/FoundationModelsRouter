---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bn045tb1kqx2jczwr325cw
  text: |-
    ### Extras API (from foundationmodelsextras-47)
    - Names: HubModelLoader (default of ModelPool), CoreMLModelLoader (embedding keys only, computeUnits .cpuAndNeuralEngine), CoreMLModelLoaderError. The container CoreMLEmbedding is internal and conforms to PooledEmbedding, so LoadedPooledEmbedding already accepts it.
    - Check how LiveModelLoader builds its modelLoader. It must use HubModelLoader (not MLXModelLoader) for Core ML to load.
    - Status: NOT committed in Extras yet. Blocked until the user commits it.
  timestamp: 2026-11-01T13:32:49.210122+00:00
- actor: claude-code
  id: 01m6bqn7tkn4gkh6kmrw83mf3e
  text: |-
    ### review — findings
    - evidence: review sha 778fe206~1..778fe206; counts findings 1, confirmed 1, refuted 0; Tests/FoundationModelsRouterTests/LiveModelLoaderCoreMLTests.swift:90
    - next: Fix the open finding. Then run review again.
  timestamp: 2026-11-01T14:19:18.227554+00:00
- actor: claude-code
  id: 01m6bqws0hsaexb8tf26631wey
  text: |-
    ### review — clean
    - evidence: review sha d977922b~1..d977922b, 0 findings (attempted 7, failed 0). The prior reuse finding is checked.
    - next: none. Task moved to done.
  timestamp: 2026-11-01T14:23:25.201671+00:00
position_column: done
position_ordinal: ffffffffd680
title: Use a CoreML embedding model through the router
---
Make LiveModelLoader and PooledEmbeddingContainer accept the new Extras CoreML container. Keep the embed span attributes (model.ref, embedding.dimension). Add a unit test with a stub container. Add a gated real-model test in IntegrationTests. Depends on the Extras CoreML container task.

## Review Findings (2026-11-01 08:16)

> Scope: `review sha 778fe206~1..778fe206` — reviewed the diffs only — lines this change added or modified. 17 file(s) reviewed, 1 not reviewed. Commit 778fe206 is shared with ^9v4bgv5.

- [x] `Tests/FoundationModelsRouterTests/LiveModelLoaderCoreMLTests.swift:90` `reuse/reuse` — The new makeCache helper rebuilds the fake Hugging Face cache layout (models--<org>--<name>/refs/main and snapshots/<commit>) that LiveModelLoaderCacheFolderTests already builds. Two copies of the same layout can drift apart. A change to the cache layout must then be made in two places. Move the fake-cache builder into one shared test helper, for example a static func in the test support folder that takes the ref, the commit, and the file map. Both suites then call it. Keep the per-suite constants (ref, commit, file paths) in each suite.
