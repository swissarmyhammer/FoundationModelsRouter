---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m4v70eezwfksrdtemzh32ezd
  text: Done. Extras step 1 agrees with mailbox.md. Package.resolved points to e454d7c (gitignored, no commit). Router build passes. Reviewer accepted.
  timestamp: 2026-10-13T18:04:46.943109+00:00
position_column: done
position_ordinal: ffffffd480
title: 'T0: Check Extras step 1 and update Package.resolved'
---
Read the Extras commits 2502826, 9c3d32b and e454d7c. Compare them with mailbox.md sections 4 and 5. Confirm that the Extras CI on origin/main passed. Run `swift package update FoundationModelsExtras` so that Package.resolved points to e454d7c or later. Build Router. Report each problem. #mail