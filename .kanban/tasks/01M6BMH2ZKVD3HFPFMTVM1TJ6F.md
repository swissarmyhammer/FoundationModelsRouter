---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m6bmtm1y9yk25sq2sm4ys5cd
  text: |-
    ### finish iteration 1 — changed
    - implement: changed — docs/ane-embedding.md, README.md (worktree commit c3ba0df8, cherry-picked)
    - test: not run (docs only)
    - commit: a4d7968e
    - next: review
  timestamp: 2026-11-01T13:29:48.862914+00:00
- actor: claude-code
  id: 01m6bmve9f4c0n7jz6qqsfr7se
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD; counts findings 0, confirmed 0, refuted 0. README.md and docs/ane-embedding.md were not reviewed: no validator matches these files.
    - next: none. The task is moved to done.
  timestamp: 2026-11-01T13:30:15.727148+00:00
position_column: done
position_ordinal: ffffffffd180
title: Document ANE embedding models
---
Add a short note in docs/ about ANE embedding models and how the router detects them. Link it from the README. Do not run swift format.