---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: 'T0: Check Extras step 1 and update Package.resolved'
---
Read the Extras commits 2502826, 9c3d32b and e454d7c. Compare them with mailbox.md sections 4 and 5. Confirm that the Extras CI on origin/main passed. Run `swift package update FoundationModelsExtras` so that Package.resolved points to e454d7c or later. Build Router. Report each problem. #mail