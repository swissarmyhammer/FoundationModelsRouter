---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bpma72rnpjhqn0074jwvk8
  text: |-
    ### review — clean
    - evidence: review sha 845b7a3c~1..845b7a3c, counts findings 0, confirmed 0, refuted 0. Two files reviewed. README.md not reviewed because no validator matches it.
    - next: none. Task moved to done.
  timestamp: 2026-11-01T14:01:19.330833+00:00
position_column: done
position_ordinal: ffffffffd380
title: Set erjigit17/embeddinggemma-300m-ane-coreml as default embedding model
---
Put erjigit17/embeddinggemma-300m-ane-coreml as the embedding model in README.md, Examples/CompactionDemo/main.swift and Examples/MultiModelGeneration/main.swift. Check if the router has a default profile in code (none found so far). The model must use the ANE. Depends on the Extras task that loads this model.