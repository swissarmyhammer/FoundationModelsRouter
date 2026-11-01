---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6br3zbrgafexf1k0dcmtbza
  text: |-
    ### review — clean
    - evidence: review sha b4d99b4e~1..b4d99b4e — counts findings 0, confirmed 0, refuted 0, attempted 7, failed 0. docs/ane-embedding.md had no matching validator.
    - next: none, task moved to done
  timestamp: 2026-11-01T14:27:21.080721+00:00
position_column: done
position_ordinal: ffffffffd780
title: Use the Extras HubModelFormat.detect rule for Core ML sizing
---
Extras made the Core ML detection rule public: `HubModelFormat` (enum, cases .mlx and .coreML) with `public static func detect(paths: [String]) -> HubModelFormat` (Extras commit 650b0ba, local on main; the Extras session will say when it is pushed). Rule: Core ML only when a path has a .mlpackage component and no path ends in .safetensors at any depth. Otherwise .mlx. A repo with only .mlmodelc is .mlx, because CoreMLModelLoader compiles a .mlpackage itself and cannot load a ready .mlmodelc.

Change the router to this one rule: RepoMetadata.isCoreMLEmbedding and the weight sizing in RepoMetadata must call HubModelFormat.detect instead of the router rule (no root .safetensors, .mlpackage or .mlmodelc). Size only .mlpackage bundles for a Core ML repo. A nested .safetensors next to a package is MLX. Update the tests in RepoMetadataTests (mlmodelc-only repo, nested safetensors repo), the Router.footprintBytes slot rule, and docs/ane-embedding.md ("How the router detects a Core ML model"). Depends on the Extras push of 650b0ba; then update the Extras pin.