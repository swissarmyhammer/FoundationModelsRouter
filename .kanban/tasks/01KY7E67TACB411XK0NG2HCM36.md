---
depends_on:
- 01KXTFS4FNT1P5F889D1PEQ9N7
position_column: todo
position_ordinal: '9380'
title: Mid-turn fill reporting + typed hard-ceiling budget error at the generate boundary
---
Harness plan §5.1 absorbed. The native loop never yields mid-turn; the generate boundary inside RoutedSession is the only seam. (a) per-inner-call measured fill surfaced live — feeds the observable state's context meter during the turn, not just at its end; (b) optional hard ceiling: fail fast with a typed budget error BEFORE submitting a doomed generate — deterministic, caught by auto-compaction's retry-once. Parked research question (recorded, not asked): rewriting the forwarded transcript (fold-below-the-session) — rejected for v1, session/model view divergence.