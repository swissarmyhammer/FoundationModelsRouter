---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bn02jd3kk67d7ve7c6bg64
  text: |-
    ### Extras API (from foundationmodelsextras-47)
    - Extras detects Core ML itself: HubModelLoader is the new default of ModelPool. For an .embedding key, Core ML means a .mlpackage folder and no .safetensors file. Everything else goes to MLX.
    - So the router does not need a second detector. This task must use the Extras result, or make the router ask the same check for sizing (see the sizing task).
    - Status: written and passing in the Extras working tree, NOT committed. The router cannot build against it until the user commits Extras.
  timestamp: 2026-11-01T13:32:47.565669+00:00
- actor: claude-code
  id: 01m6bqn6jc0h9wptw6wthd8hhj
  text: |-
    ### review — findings
    - evidence: review sha 778fe206~1..778fe206; counts findings 1, confirmed 1, refuted 0; Tests/FoundationModelsRouterTests/LiveModelLoaderCoreMLTests.swift:90
    - next: Fix the open finding. Then run review again.
  timestamp: 2026-11-01T14:19:16.940632+00:00
- actor: claude-code
  id: 01m6bqwqqe58d5j1jzcrvg5482
  text: |-
    ### review — clean
    - evidence: review sha d977922b~1..d977922b, 0 findings (attempted 7, failed 0). The prior reuse finding is checked.
    - next: none. Task moved to done.
  timestamp: 2026-11-01T14:23:23.886019+00:00
position_column: done
position_ordinal: ffffffffd580
title: Detect a CoreML embedding model in the router
---
Report from the repo metadata if a ref is a CoreML (ANE) embedding model. Use the Extras detection when it exposes one. Do not write a second detector. Make resolution of the embedding slot use this check. Add unit tests. Depends on the Extras tasks for ANE embedding support (foundationmodelsextras-47 will send the API names).

## Review Findings (2026-11-01 08:16)

> Scope: `review sha 778fe206~1..778fe206` — reviewed the diffs only — lines this change added or modified. 17 file(s) reviewed, 1 not reviewed. Commit 778fe206 is shared with ^05fnq6n.

- [x] `Tests/FoundationModelsRouterTests/LiveModelLoaderCoreMLTests.swift:90` `reuse/reuse` — The new makeCache helper rebuilds the fake Hugging Face cache layout (models--<org>--<name>/refs/main and snapshots/<commit>) that LiveModelLoaderCacheFolderTests already builds. Two copies of the same layout can drift apart. A change to the cache layout must then be made in two places. Move the fake-cache builder into one shared test helper, for example a static func in the test support folder that takes the ref, the commit, and the file map. Both suites then call it. Keep the per-suite constants (ref, commit, file paths) in each suite.
